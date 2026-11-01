import FSCore

/// One allocating write's changes, gathered before any is written (roadmap 0026 step 2): blocks taken from the bitmaps, the
/// group descriptors' counts, and the indirect blocks that map the file's new blocks.
///
/// What is new (data blocks, indirect blocks never linked before) is written and flushed before what links it (existing
/// indirect blocks, the inode), so a crash leaves at worst blocks marked used that nothing points to, which e2fsck's preen
/// gives back.
struct ExtAllocation {
    let superblock: ExtSuperblock
    let device: any WritableBlockSource
    /// Free blocks on the volume as the session left them.
    var freeBlocks: UInt64
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

    /// Blocks `logical` needs that it has not: at most one indirect block per level, for a new range of pointers.
    func worstCase(missing: UInt64) -> UInt64 {
        let perBlock = UInt64(pointersPerBlock)
        return missing + missing / perBlock + 3
    }

    // MARK: Blocks

    /// A free block, nearest at or after `goal` and wrapping: its bitmap bit set and its group's free count lowered.
    mutating func allocate() throws(DiskError) -> UInt64 {
        let perGroup = UInt64(superblock.blocksPerGroup)
        let first = superblock.firstDataBlock
        let groups = superblock.groupCount
        let start = goal >= first && goal < superblock.blockCount ? goal : first
        let startGroup = (start - first) / perGroup
        for step in 0 ... groups {
            let group = (startGroup + step) % groups
            let descriptor = try descriptorLocation(group)
            var table = try load(descriptor.block)
            guard try freeCount(in: table, at: descriptor.offset) > 0 else { continue }
            let bitmapBlock = try bitmap(group, in: table, at: descriptor.offset)
            var bits = try load(bitmapBlock)
            let blocksInGroup = Int(min(perGroup, superblock.blockCount - first - group * perGroup))
            let from = step == 0 ? Int((start - first) % perGroup) : 0
            for bit in (from ..< blocksInGroup) where bits[bit / 8] & (1 << (bit % 8)) == 0 {
                bits[bit / 8] |= 1 << (bit % 8)
                metadata[bitmapBlock] = bits
                setFreeCount(try freeCount(in: table, at: descriptor.offset) - 1, in: &table, at: descriptor.offset)
                metadata[descriptor.block] = table
                let block = first + group * perGroup + UInt64(bit)
                allocated.append(block)
                freeBlocks -= 1
                goal = block + 1
                return block
            }
        }
        throw .noSpace
    }

    /// `bg_free_blocks_count`, with its high half on a 64-bit volume's wide descriptors.
    private func freeCount(in table: [UInt8], at offset: Int) throws(DiskError) -> UInt32 {
        let bytes = DiskBytes(table)
        let high = wide ? UInt32(try bytes.u16(offset + 0x2C)) << 16 : 0
        return high | UInt32(try bytes.u16(offset + 0x0C))
    }

    private func setFreeCount(_ count: UInt32, in table: inout [UInt8], at offset: Int) {
        ExtFileSystem.put16(UInt16(truncatingIfNeeded: count), at: offset + 0x0C, in: &table)
        if wide { ExtFileSystem.put16(UInt16(truncatingIfNeeded: count >> 16), at: offset + 0x2C, in: &table) }
    }

    private var wide: Bool { superblock.is64Bit && superblock.descriptorSize >= 64 }

    private func descriptorLocation(_ group: UInt64) throws(DiskError) -> (block: UInt64, offset: Int) {
        let perBlock = UInt64(superblock.blockSize / superblock.descriptorSize)
        let block = superblock.descriptors.descriptorBlock(group / perBlock)
        return (block, Int(group % perBlock) * superblock.descriptorSize)
    }

    private func bitmap(_ group: UInt64, in table: [UInt8], at offset: Int) throws(DiskError) -> UInt64 {
        let bytes = DiskBytes(table)
        let high = wide ? UInt64(try bytes.u32(offset + 0x20)) << 32 : 0
        let block = high | UInt64(try bytes.u32(offset))
        guard block > 0, block < superblock.blockCount else {
            throw .corrupt("group \(group): block bitmap at \(block)")
        }
        return block
    }

    /// A block as this allocation left it, else as the device has it.
    private func load(_ block: UInt64) throws(DiskError) -> [UInt8] {
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
