import Dispatch
import FSCore
import Testing

/// A writer invalidates what it changed (ADR-0018): the value goes, and a make already under way when it does keeps its
/// result for its own caller (it began before the write) but does not cache it, or a stale block would outlive the write.
struct BoundedCacheInvalidationTests {
    @Test func anInvalidatedValueIsMadeAgain() {
        let cache = BoundedCache<Int, String>(capacity: 4)
        cache.insert("old", for: 1)
        cache.invalidate(1)
        #expect(cache[1] == nil)
        #expect(cache.value(for: 1) { "new" } == "new")
    }

    @Test func aMakeUnderWayWhenInvalidatedIsNotCached() {
        let cache = BoundedCache<Int, String>(capacity: 4)
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global()
            .async {
                let made = cache.value(for: 1) { () -> String in
                    started.signal()
                    proceed.wait()
                    return "stale"
                }
                #expect(made == "stale")
                finished.signal()
            }
        started.wait()
        cache.invalidate(1)
        proceed.signal()
        finished.wait()
        #expect(cache[1] == nil)
        #expect(cache.value(for: 1) { "fresh" } == "fresh")
    }
}
