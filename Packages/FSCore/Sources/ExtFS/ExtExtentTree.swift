import FSCore

/// The extent tree of an inode (`ext4_extent_header`, `ext4_extent_idx`, `ext4_extent`).
enum ExtExtentTree {
    private static let magic: UInt16 = 0xF30A
    private static let maximumDepth: UInt16 = 5

    /// Every extent, in logical order. Uninitialized extents (allocated, never written) are holes.
    static func runs(_ root: DiskBytes, number: UInt64, readBlock: (UInt64) throws(DiskError) -> DiskBytes)
        throws(DiskError) -> [ExtRun]
    {
        var runs: [ExtRun] = []
        var pending: [(node: DiskBytes, depth: UInt16?)] = [(root, nil)]
        var visited = 0
        while let (node, expected) = pending.popLast() {
            visited += 1
            guard visited <= 1 << 20 else { throw .corrupt("inode \(number): extent tree too large") }
            guard try node.u16(0) == magic else { throw .corrupt("inode \(number): extent header magic") }
            let entries = Int(try node.u16(2))
            let depth = try node.u16(6)
            guard depth <= maximumDepth, expected.map({ $0 == depth }) ?? true, 12 + 12 * entries <= node.count else {
                throw .corrupt("inode \(number): extent node of depth \(depth) with \(entries) entries")
            }
            if depth == 0 {
                for index in 0 ..< entries {
                    let at = 12 + 12 * index
                    var length = UInt64(try node.u16(at + 4))
                    let unwritten = length > 32768
                    if unwritten { length -= 32768 }
                    let start = UInt64(try node.u16(at + 6)) << 32 | UInt64(try node.u32(at + 8))
                    runs.append(
                        ExtRun(logical: UInt64(try node.u32(at)), physical: unwritten ? nil : start, count: length))
                }
                continue
            }
            var children: [DiskBytes] = []
            for index in 0 ..< entries {
                let at = 12 + 12 * index
                let leaf = UInt64(try node.u16(at + 8)) << 32 | UInt64(try node.u32(at + 4))
                children.append(try readBlock(leaf))
            }
            for child in children.reversed() { pending.append((child, depth - 1)) }
        }
        for (previous, next) in zip(runs, runs.dropFirst()) where previous.end > next.logical {
            throw .corrupt("inode \(number): extents overlap at block \(next.logical)")
        }
        return runs
    }
}
