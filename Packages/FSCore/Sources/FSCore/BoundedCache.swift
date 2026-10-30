public import Synchronization

/// A thread-safe map with a capacity. When full, inserting evicts the least recently inserted half,
/// which is cheap and good enough for metadata blocks: a hot block is simply read again. Inlinable, so each reader's
/// module specializes it: unspecialized, every call looks its dictionary's generic metadata up at run time, which costs
/// more than the lookup (a hashed XFS lookup makes three).
public final class BoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    @usableFromInline struct State {
        @usableFromInline var values: [Key: Value] = [:]
        @usableFromInline var order: [Key] = []
        @usableFromInline init() {}
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

    /// The cached value, or the result of `make`, which is then cached. `make` runs outside the lock,
    /// so two callers may both compute a missing value; the second insert wins and both are equal.
    @inlinable public func value<E: Error>(for key: Key, _ make: () throws(E) -> Value) throws(E) -> Value {
        if let hit = self[key] { return hit }
        let made = try make()
        insert(made, for: key)
        return made
    }
}
