public import Dispatch
public import Synchronization

/// A thread-safe map with a capacity. When full, inserting evicts the least recently inserted half,
/// which is cheap and good enough for metadata blocks: a hot block is simply read again. Inlinable, so each reader's
/// module specializes it: unspecialized, every call looks its dictionary's generic metadata up at run time, which costs
/// more than the lookup (a hashed XFS lookup makes three).
public final class BoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    @usableFromInline struct State {
        @usableFromInline var values: [Key: Value] = [:]
        @usableFromInline var order: [Key] = []
        /// Keys being made: their callers wait on the maker instead of making them again.
        @usableFromInline var making: [Key: Making] = [:]
        @usableFromInline init() {}
    }

    /// One make in progress; waiters block on `done` outside the lock.
    @usableFromInline final class Making: Sendable {
        @usableFromInline let done = DispatchGroup()
        @usableFromInline init() { done.enter() }
    }

    @usableFromInline enum Claim {
        case hit(Value)
        case wait(Making)
        case make(Making)
    }

    @usableFromInline let capacity: Int
    @usableFromInline let state: Mutex<State> = Mutex(State())

    public init(capacity: Int) {
        precondition(capacity > 1, "a cache needs room for at least two entries")
        self.capacity = capacity
    }

    @inlinable public subscript(key: Key) -> Value? {
        state.withLock { $0.values[key] }
    }

    @inlinable public func insert(_ value: Value, for key: Key) {
        state.withLock { state in
            if state.values.updateValue(value, forKey: key) != nil { return }
            state.order.append(key)
            if state.order.count > capacity {
                let evicted = state.order.prefix(capacity / 2)
                for old in evicted { state.values[old] = nil }
                state.order.removeFirst(evicted.count)
            }
        }
    }

    /// The cached value, or the result of `make`, which is then cached. `make` runs outside the lock, once however many
    /// callers miss the same key together (Everest's in-flight fetches): the others wait for it, then take its value, or make
    /// it themselves if it failed. So `make` must not wait for a key whose maker waits for this one.
    @inlinable public func value<E: Error>(for key: Key, _ make: () throws(E) -> Value) throws(E) -> Value {
        while true {
            let claim = state.withLock { state -> Claim in
                if let hit = state.values[key] { return .hit(hit) }
                if let making = state.making[key] { return .wait(making) }
                let making = Making()
                state.making[key] = making
                return .make(making)
            }
            switch claim {
                case .hit(let value):
                    return value
                case .wait(let making):
                    making.done.wait()
                case .make(let making):
                    defer {
                        _ = state.withLock { $0.making.removeValue(forKey: key) }
                        making.done.leave()
                    }
                    let made = try make()
                    insert(made, for: key)
                    return made
            }
        }
    }
}
