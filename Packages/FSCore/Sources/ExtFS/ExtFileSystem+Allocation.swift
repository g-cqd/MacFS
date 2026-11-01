import FSCore

extension ExtFileSystem {
    /// A write that needs blocks (roadmap 0026 step 2): new data and indirect blocks taken and written, flushed, then linked
    /// from the existing indirect blocks and the inode. Returns the free counts left.
    func allocatingWrite(
        _ inode: ExtInode,
        runs: [ExtRun],
        at offset: UInt64,
        _ bytes: [UInt8],
        on device: any WritableBlockSource,
        free: ExtFreeCounts
    ) throws(DiskError) -> ExtFreeCounts {
        guard inode.flags & ExtInode.extentsFlag == 0 else {
            throw .unsupported("growing an extent-mapped file (a later slice)")
        }
        guard superblock.clusterSize == superblock.blockSize, !superblock.hasGroupDescriptorChecksums else {
            throw .unsupported("allocating on a volume with clusters or descriptor checksums (a later slice)")
        }
        let blockSize = UInt64(superblock.blockSize)
        let end = offset + UInt64(bytes.count)
        let first = offset / blockSize
        let last = (end - 1) / blockSize
        func physical(_ logical: UInt64) -> UInt64? {
            guard let run = runs.first(where: { $0.logical <= logical && logical < $0.end }), let start = run.physical
            else {
                return nil
            }
            return start + logical - run.logical
        }
        let missing = (first ... last).filter { physical($0) == nil }
        var allocation = try allocation(for: inode, on: device, free: free)
        guard allocation.worstCase(missing: UInt64(missing.count)) <= free.blocks else { throw .noSpace }
        // Phase one: what is new, and the bytes of blocks already stored.
        for logical in first ... last {
            let blockStart = logical * blockSize
            let from = Int(max(offset, blockStart) - offset)
            let to = Int(min(end, blockStart + blockSize) - offset)
            if let stored = physical(logical) {
                try device.write(
                    at: stored * blockSize + (max(offset, blockStart) - blockStart),
                    Array(bytes[from ..< to])
                )
            } else {
                let block = try allocation.allocate()
                try allocation.link(logical, to: block)
                var content = [UInt8](repeating: 0, count: Int(blockSize))
                content.replaceSubrange(
                    Int(max(offset, blockStart) - blockStart) ..< Int(max(offset, blockStart) - blockStart)
                        + (to - from),
                    with: bytes[from ..< to]
                )
                try device.write(at: block * blockSize, content)
            }
        }
        // A gap after the old end: the rest of the old last block reads as zeros.
        if offset > inode.size, inode.size % blockSize != 0, let stored = physical(inode.size / blockSize) {
            let from = inode.size % blockSize
            let to = min(blockSize, offset - inode.size / blockSize * blockSize)
            if to > from {
                try device.write(at: stored * blockSize + from, [UInt8](repeating: 0, count: Int(to - from)))
            }
        }
        try writeAllocation(allocation, on: device)
        try device.flush()
        // Phase two: the links.
        for (block, content) in allocation.changedIndirectBlocks { try device.write(at: block * blockSize, content) }
        let sectors = inode.sectors + UInt64(allocation.allocated.count) * blockSize / 512
        guard sectors <= UInt64(UInt32.max) else { throw .unsupported("a file of more than 2 TiB of sectors") }
        try touch(inode, on: device) { raw in
            for (index, pointer) in allocation.pointers.enumerated() {
                Self.put32(pointer, at: 0x28 + index * 4, in: &raw)
            }
            let size = max(inode.size, end)
            Self.put32(UInt32(truncatingIfNeeded: size), at: 0x04, in: &raw)
            Self.put32(UInt32(truncatingIfNeeded: size >> 32), at: 0x6C, in: &raw)
            Self.put32(UInt32(sectors), at: 0x1C, in: &raw)
        }
        for block in allocation.metadata.keys { blocks.invalidate(block) }
        for block in allocation.indirect.keys { blocks.invalidate(block) }
        mappings.invalidate(inode.number)
        return allocation.free
    }
}
