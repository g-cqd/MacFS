import FSCore
import Synchronization

extension ExtFileSystem {
    /// `body` with no other change running: every public change goes through here, and none calls another.
    func serialized<T: Sendable>(_ body: () throws(DiskError) -> T) throws(DiskError) -> T {
        try changeLock.withLock { (_) throws(DiskError) -> T in try body() }
    }
}
