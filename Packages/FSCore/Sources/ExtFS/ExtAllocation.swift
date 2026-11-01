import FSCore

/// One change's allocations, gathered before any is written (roadmap 0026 steps 2 and 3): blocks and inodes taken from or
/// given back to the bitmaps, the group descriptors' counts, and the indirect blocks that map a file's new blocks.
///
/// What is new (data blocks, indirect blocks never linked before) is written and flushed before what links it (existing
/// indirect blocks, the inode), so a crash leaves at worst blocks marked used that nothing points to, which e2fsck's preen
/// gives back.
struct ExtAllocation {
    let superblock: ExtSuperblock
    let device: any WritableBlockSource
    var free: ExtFreeCounts
    /// The bitmap and descriptor blocks changed, by block number.
    private(set) var metadata: [UInt64: [UInt8]] = [:]
    /// Indirect blocks changed or created, and which of them are new.
    private(set) var indirect: [UInt64: [UInt8]] = [:]
    private(set) var newIndirect: Set<UInt64> = []
    private(set) var allocated: [UInt64] = []
    /// The inode's 15 block pointers.
    var pointers: [UInt32]
    /// Where the next block is sought: after the last one taken.
    var goal: UInt64

    var blockSize: Int { superblock.blockSize }
    var pointersPerBlock: Int { blockSize / 4 }

    /// The most blocks `missing` new data blocks can take: theirs, and at most one indirect block per level per new range.
    func worstCase(missing: UInt64) -> UInt64 {
        let perBlock = UInt64(pointersPerBlock)
        return missing + missing / perBlock + 3
    }

    // MARK: Bitmaps

    /// The two bitmaps of a group, as their fields in its descriptor: the bitmap's block (low and high halves) and the free
    /// count (low and high halves).
    struct Bitmap {
        let block: (low: Int, high: Int)
        let count: (low: Int, high: Int)
        static let blocks = Bitmap(block: (0x00, 0x20), count: (0x0C, 0x2C))
        static let inodes = Bitmap(block: (0x04, 0x24), count: (0x0E, 0x2E))
    }

    /// A free block, nearest at or after `goal` and wrapping: its bit set, its group's free count lowered.
    mutating func allocate() throws(DiskError) -> UInt64 {
        let first = superblock.firstDataBlock
        let start = goal >= first && goal < superblock.blockCount ? goal - first : 0
        let perGroup = UInt64(superblock.blocksPerGroup)
        let count = superblock.blockCount
        let taken = try take(.blocks, from: start, perGroup: perGroup) { group in
            Int(min(perGroup, count - first - group * perGroup))
        }
        let block = first + taken
        allocated.append(block)
        free.blocks -= 1
        goal = block + 1
        return block
    }

    /// A free inode, in `group` or the next one with room; a directory also counts in its group's directories.
    mutating func allocateInode(near group: UInt64, directory: Bool) throws(DiskError) -> UInt64 {
        let perGroup = UInt64(superblock.inodesPerGroup)
        let taken = try take(.inodes, from: group * perGroup, perGroup: perGroup) { _ in Int(perGroup) }
        let number = taken + 1
        guard number >= UInt64(superblock.firstInode) else { throw .corrupt("inode \(number) is reserved") }
        if directory { try countDirectories(in: taken / perGroup, by: 1) }
        free.inodes -= 1
        return number
    }

    /// Block `block` given back: its bit cleared, its group's free count raised.
    mutating func free(block: UInt64) throws(DiskError) {
        try give(.blocks, back: block - superblock.firstDataBlock, perGroup: UInt64(superblock.blocksPerGroup))
        free.blocks += 1
    }

    mutating func free(inode number: UInt64, directory: Bool) throws(DiskError) {
        let perGroup = UInt64(superblock.inodesPerGroup)
        try give(.inodes, back: number - 1, perGroup: perGroup)
        if directory { try countDirectories(in: (number - 1) / perGroup, by: -1) }
        free.inodes += 1
    }

    /// The first clear bit at or after `start` (an index from the bitmaps' origin), wrapping; set, and counted.
    private mutating func take(
        _ bitmap: Bitmap,
        from start: UInt64,
        perGroup: UInt64,
        bitsIn: (UInt64) -> Int
    ) throws(DiskError) -> UInt64 {
        let groups = superblock.groupCount
        let startGroup = start / perGroup % groups
        for step in 0 ... groups {
            let group = (startGroup + step) % groups
            let descriptor = try descriptorLocation(group)
            var table = try load(descriptor.block)
            // A count of 0 is believed even over free bits, which would take it below zero.
            let count = try field(bitmap.count, in: table, at: descriptor.offset, wide: 16)
            guard count > 0 else { continue }
            let bitmapBlock = try bitmapLocation(bitmap, group, in: table, at: descriptor.offset)
            var bits = try load(bitmapBlock)
            let from = step == 0 ? Int(start % perGroup) : 0
            for bit in from ..< bitsIn(group) where bits[bit / 8] & (1 << (bit % 8)) == 0 {
                bits[bit / 8] |= 1 << (bit % 8)
                metadata[bitmapBlock] = bits
                setField(bitmap.count, to: count - 1, in: &table, at: descriptor.offset, wide: 16)
                metadata[descriptor.block] = table
                return group * perGroup + UInt64(bit)
            }
        }
        throw .noSpace
    }

    private mutating func give(_ bitmap: Bitmap, back index: UInt64, perGroup: UInt64) throws(DiskError) {
        let group = index / perGroup
        let bit = Int(index % perGroup)
        let descriptor = try descriptorLocation(group)
        var table = try load(descriptor.block)
        let bitmapBlock = try bitmapLocation(bitmap, group, in: table, at: descriptor.offset)
        var bits = try load(bitmapBlock)
        guard bits[bit / 8] & (1 << (bit % 8)) != 0 else { throw .corrupt("freeing \(index), which is free") }
        bits[bit / 8] &= ~(1 << (bit % 8))
        metadata[bitmapBlock] = bits
        let count = try field(bitmap.count, in: table, at: descriptor.offset, wide: 16)
        setField(bitmap.count, to: count + 1, in: &table, at: descriptor.offset, wide: 16)
        metadata[descriptor.block] = table
    }

    /// `bg_used_dirs_count`, raised or lowered.
    private mutating func countDirectories(in group: UInt64, by change: Int) throws(DiskError) {
        let descriptor = try descriptorLocation(group)
        var table = try load(descriptor.block)
        let count = try field((0x10, 0x30), in: table, at: descriptor.offset, wide: 16)
        guard change > 0 || count > 0 else { throw .corrupt("group \(group): no directory to remove") }
        setField((0x10, 0x30), to: change > 0 ? count + 1 : count - 1, in: &table, at: descriptor.offset, wide: 16)
        metadata[descriptor.block] = table
    }

    /// A descriptor field of 16 bits, or 32 with its high half in a 64-bit volume's wide descriptors (`wide` is the low
    /// half's width).
    private func field(_ offsets: (low: Int, high: Int), in table: [UInt8], at offset: Int, wide: Int) throws(DiskError)
        -> UInt64
    {
        let bytes = DiskBytes(table)
        let low = wide == 16 ? UInt64(try bytes.u16(offset + offsets.low)) : UInt64(try bytes.u32(offset + offsets.low))
        guard isWide else { return low }
        let high =
            wide == 16 ? UInt64(try bytes.u16(offset + offsets.high)) : UInt64(try bytes.u32(offset + offsets.high))
        return high << wide | low
    }

    private func setField(
        _ offsets: (low: Int, high: Int),
        to value: UInt64,
        in table: inout [UInt8],
        at offset: Int,
        wide: Int
    ) {
        ExtFileSystem.put16(UInt16(truncatingIfNeeded: value), at: offset + offsets.low, in: &table)
        if isWide {
            ExtFileSystem.put16(UInt16(truncatingIfNeeded: value >> 16), at: offset + offsets.high, in: &table)
        }
    }

    private var isWide: Bool { superblock.is64Bit && superblock.descriptorSize >= 64 }

    private func descriptorLocation(_ group: UInt64) throws(DiskError) -> (block: UInt64, offset: Int) {
        let perBlock = UInt64(superblock.blockSize / superblock.descriptorSize)
        let block = superblock.descriptors.descriptorBlock(group / perBlock)
        return (block, Int(group % perBlock) * superblock.descriptorSize)
    }

    private func bitmapLocation(
        _ bitmap: Bitmap,
        _ group: UInt64,
        in table: [UInt8],
        at offset: Int
    ) throws(DiskError) -> UInt64 {
        let block = try field(bitmap.block, in: table, at: offset, wide: 32)
        guard block > 0, block < superblock.blockCount else { throw .corrupt("group \(group): bitmap at \(block)") }
        return block
    }

    /// A block as this allocation left it, else as the device has it.
    func load(_ block: UInt64) throws(DiskError) -> [UInt8] {
        if let changed = metadata[block] ?? indirect[block] { return changed }
        return try device.read(at: block * UInt64(blockSize), count: blockSize)
    }

    // MARK: Indirect blocks

    /// Points the file's block `logical` at `physical`, allocating the indirect blocks on the way (ext2's map: twelve direct
    /// pointers, then single, double and triple indirect blocks).
    mutating func link(_ logical: UInt64, to physical: UInt64) throws(DiskError) {
        let perBlock = UInt64(pointersPerBlock)
        var rest = logical
        guard rest >= 12 else {
            pointers[Int(rest)] = UInt32(physical)
            return
        }
        rest -= 12
        var depth = 1
        var span = perBlock
        while rest >= span {
            rest -= span
            depth += 1
            guard depth <= 3 else { throw .unsupported("a file past the triple indirect block") }
            span *= perBlock
        }
        let slot = 11 + depth
        if pointers[slot] == 0 { pointers[slot] = UInt32(try newIndirectBlock()) }
        var block = UInt64(pointers[slot])
        for level in (0 ..< depth).reversed() {
            let index = Int(rest / power(perBlock, level) % perBlock)
            var bytes = try load(block)
            if level == 0 {
                ExtFileSystem.put32(UInt32(physical), at: index * 4, in: &bytes)
                indirect[block] = bytes
                return
            }
            var next = UInt64(try DiskBytes(bytes).u32(index * 4))
            if next == 0 {
                next = try newIndirectBlock()
                ExtFileSystem.put32(UInt32(next), at: index * 4, in: &bytes)
                indirect[block] = bytes
            }
            block = next
        }
    }

    private func power(_ base: UInt64, _ exponent: Int) -> UInt64 {
        (0 ..< exponent).reduce(1) { value, _ in value * base }
    }

    private mutating func newIndirectBlock() throws(DiskError) -> UInt64 {
        let block = try allocate()
        indirect[block] = [UInt8](repeating: 0, count: blockSize)
        newIndirect.insert(block)
        return block
    }

    /// New indirect blocks, written before anything points to them; then the existing ones they are linked through.
    var newIndirectBlocks: [(UInt64, [UInt8])] {
        indirect.filter { newIndirect.contains($0.key) }.sorted { $0.key < $1.key }
    }
    var changedIndirectBlocks: [(UInt64, [UInt8])] {
        indirect.filter { !newIndirect.contains($0.key) }.sorted { $0.key < $1.key }
    }
}
