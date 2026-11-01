import FSCore

/// Where names go in a linear directory (roadmap 0026 step 3): its blocks, the one with room, or one it grows by.
extension ExtFileSystem {
    /// `name` for inode `number` added to `directory`, in a block with room or in a block the directory grows by. Blocks
    /// nothing points to yet (`writingFirst`, a grown block) and the allocation's bitmaps are written and flushed first; then
    /// the name, and the directory's new pointers and size; flushed. Returns the block that holds the name.
    func addName(
        _ name: [UInt8],
        inode number: UInt64,
        kind: NodeKind,
        in directory: ExtInode,
        allocation: inout ExtAllocation,
        writingFirst: [(UInt64, [UInt8])] = [],
        on device: any WritableBlockSource
    ) throws(DiskError) -> UInt64? {
        let blockSize = UInt64(superblock.blockSize)
        let type = superblock.incompat & 0x0002 != 0 ? Self.typeCode(kind) : 0
        let before = allocation.allocated.count
        let placed = try place(name, inode: number, type: type, in: directory, allocation: &allocation)
        for (block, bytes) in writingFirst { try device.write(at: block * blockSize, bytes) }
        if placed.grown, let (block, bytes) = placed.block { try device.write(at: block * blockSize, bytes) }
        try writeAllocation(allocation, on: device)
        try device.flush()
        // The name. A crash after it leaves a name for an inode not yet written, which preen clears; an unconnected directory
        // it would not reconnect.
        if !placed.grown, let (block, bytes) = placed.block { try device.write(at: block * blockSize, bytes) }
        for (block, content) in allocation.changedIndirectBlocks { try device.write(at: block * blockSize, content) }
        let grownSectors = UInt64(allocation.allocated.count - before) * blockSize / 512
        let pointers = allocation.pointers
        try touch(directory, on: device) { raw in
            guard placed.grown else { return }
            for (index, pointer) in pointers.enumerated() { Self.put32(pointer, at: 0x28 + index * 4, in: &raw) }
            Self.put32(UInt32(directory.size + blockSize), at: 0x04, in: &raw)
            Self.put32(UInt32(directory.sectors + grownSectors), at: 0x1C, in: &raw)
        }
        try device.flush()
        return placed.block?.0
    }

    /// The directory's stored blocks, as (logical, physical).
    func directoryBlocks(_ directory: ExtInode) throws(DiskError) -> [(UInt64, UInt64)] {
        try runs(directory)
            .flatMap { run -> [(UInt64, UInt64)] in
                guard let physical = run.physical else { return [] }
                return (0 ..< run.count).map { (run.logical + $0, physical + $0) }
            }
    }

    /// Where the entry goes: an existing block with room, or a new one the directory grows by (allocated and linked through
    /// `allocation`).
    func place(
        _ name: [UInt8],
        inode number: UInt64,
        type: UInt8,
        in directory: ExtInode,
        allocation: inout ExtAllocation
    ) throws(DiskError) -> (block: (UInt64, [UInt8])?, grown: Bool) {
        let blockSize = UInt64(superblock.blockSize)
        for (_, physical) in try directoryBlocks(directory) {
            let bytes = try openDevice().read(at: physical * blockSize, count: Int(blockSize))
            if let changed = try ExtDirectoryEntries.inserting(name, inode: UInt32(number), type: type, into: bytes) {
                return ((physical, changed), false)
            }
        }
        let block = try allocation.allocate()
        try allocation.link(directory.size / blockSize, to: block)
        let empty = ExtDirectoryEntries.emptyBlock(size: Int(blockSize))
        guard let bytes = try ExtDirectoryEntries.inserting(name, inode: UInt32(number), type: type, into: empty) else {
            throw .corrupt("a name that does not fit in an empty block")
        }
        return ((block, bytes), true)
    }
}
