import Dispatch
import FSCore
import Synchronization
import Testing

/// `BoundedCache`: bounded, and a miss computed once however many threads ask at the same time. Everest's media cache shares
/// in-flight fetches; here a Btrfs piece of 1 MiB verified by eight concurrent NFS reads was verified eight times.
@Suite struct BoundedCacheTests {
    @Test func concurrentMissesOfOneKeyMakeItOnce() {
        let cache = BoundedCache<Int, Int>(capacity: 16)
        let made = Atomic<Int>(0)
        let results = Mutex<[Int]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let value = cache.value(for: 1) {
                made.add(1, ordering: .relaxed)
                usleep(50_000)
                return 7
            }
            results.withLock { $0.append(value) }
        }
        #expect(made.load(ordering: .relaxed) == 1)
        #expect(results.withLock { $0 } == Array(repeating: 7, count: 8))
    }

    @Test func aFailedMakeLeavesTheKeyToTheNextCaller() {
        struct Failed: Error {}
        let cache = BoundedCache<Int, Int>(capacity: 16)
        let attempts = Atomic<Int>(0)
        let outcomes = Mutex<[Int?]>([])
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            let value = try? cache.value(for: 1) { () throws(Failed) -> Int in
                let attempt = attempts.add(1, ordering: .relaxed).newValue
                usleep(20_000)
                if attempt == 1 { throw Failed() }
                return 9
            }
            outcomes.withLock { $0.append(value) }
        }
        let values = outcomes.withLock { $0 }
        #expect(values.filter { $0 == nil }.count == 1, "only the failing caller fails")
        #expect(values.filter { $0 == 9 }.count == 3)
        #expect(attempts.load(ordering: .relaxed) == 2, "the failure, then one retry for the waiters")
    }

    @Test func differentKeysAreMadeConcurrently() {
        let cache = BoundedCache<Int, Int>(capacity: 16)
        let start = ContinuousClock.now
        DispatchQueue.concurrentPerform(iterations: 4) { index in
            _ = cache.value(for: index) {
                usleep(100_000)
                return index
            }
        }
        #expect(ContinuousClock.now - start < .milliseconds(300), "four makes of 100 ms overlapped")
    }

    /// Half of the capacity goes when it is full: a capacity of one would evict nothing and grow without bound.
    @Test func aCapacityBelowTwoIsRefused() async {
        _ = BoundedCache<Int, Int>(capacity: 2)
        await #expect(processExitsWith: .failure) { _ = BoundedCache<Int, Int>(capacity: 1) }
    }

    /// Full, it evicts the least recently inserted half.
    @Test func aFullCacheEvictsItsOldestHalf() {
        let cache = BoundedCache<Int, Int>(capacity: 4)
        for key in 0 ..< 4 { cache.insert(key, for: key) }
        #expect((0 ..< 4).allSatisfy { cache[$0] == $0 }, "four fit")
        cache.insert(4, for: 4)
        #expect((0 ..< 5).map { cache[$0] } == [nil, nil, 2, 3, 4])
    }

    @Test func itHoldsAtMostItsCapacity() {
        let cache = BoundedCache<Int, Int>(capacity: 4)
        for key in 0 ..< 100 { cache.insert(key, for: key) }
        #expect((0 ..< 100).filter { cache[$0] != nil }.count <= 4)
        #expect(cache[99] == 99, "the latest is kept")
    }
}
