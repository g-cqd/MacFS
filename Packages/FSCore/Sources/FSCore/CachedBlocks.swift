import AemiKernel

/// A volume's blocks by number, read whole and kept in a bounded cache: the metadata reads every reader makes (inode tables,
/// directory and tree blocks). Data is read through ``ReadAssembly`` instead, uncached.
public final class CachedBlocks: Sendable {
    private let source: any BlockSource
    private let size: Int
    private let count: UInt64
    private let cache: BoundedCache<UInt64, DiskBytes>

    public init(_ source: any BlockSource, blockSize: Int, blockCount: UInt64, capacity: Int = 1024) {
        self.source = source
        size = blockSize
        count = blockCount
        cache = BoundedCache(capacity: capacity)
    }

    /// Forgets block `number`, after a writer changed it.
    public func invalidate(_ number: UInt64) { cache.invalidate(number) }

    /// Block `number`, which must lie within the volume's `blockCount`.
    public func block(_ number: UInt64) throws(DiskError) -> DiskBytes {
        try cache.value(for: number) { () throws(DiskError) -> DiskBytes in
            guard number < count, let offset = number.checkedMultiplied(by: UInt64(size)) else {
                throw .corrupt("block \(number) of \(count)")
            }
            return DiskBytes(try source.read(at: offset, count: size))
        }
    }
}
