import FSCore
import Synchronization

/// A source that counts its reads and their bytes: a hashed lookup reads a few blocks where a scan reads the whole
/// directory. Shared by the ext and XFS tests (a link in XFSTests).
final class CountingSource: BlockSource {
    let base: any BlockSource
    let reads = Atomic<Int>(0)
    let bytes = Atomic<Int>(0)
    var byteCount: UInt64 { base.byteCount }
    init(_ base: any BlockSource) { self.base = base }

    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        reads.add(1, ordering: .relaxed)
        bytes.add(count, ordering: .relaxed)
        return try base.read(at: offset, count: count)
    }

    /// What `body` returns, and the bytes read while it ran.
    func measure<T>(_ body: () throws -> T) rethrows -> (value: T, bytes: Int) {
        let before = bytes.load(ordering: .relaxed)
        let value = try body()
        return (value, bytes.load(ordering: .relaxed) - before)
    }
}
