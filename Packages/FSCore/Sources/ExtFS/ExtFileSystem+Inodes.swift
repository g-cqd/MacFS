import FSCore

/// Inodes made and given up (roadmap 0026 step 3): a new inode's bytes, and the blocks a node owns when it goes.
extension ExtFileSystem {
    /// Every block a file or directory owns: its data blocks and its indirect blocks. A fast symlink owns none.
    func blocksOwned(by inode: ExtInode) throws(DiskError) -> [UInt64] {
        if inode.kind == .symlink, inode.sectors == 0 { return [] }
        guard inode.flags & (ExtInode.extentsFlag | ExtInode.inlineDataFlag) == 0 else {
            throw .unsupported("removing an extent-mapped or inline file (a later slice)")
        }
        var owned = try runs(inode)
            .flatMap { run -> [UInt64] in
                guard let physical = run.physical else { return [] }
                return (0 ..< run.count).map { physical + $0 }
            }
        for (slot, depth) in [(12, 1), (13, 2), (14, 3)] {
            let block = UInt64(try inode.blockArea.u32(slot * 4))
            if block != 0 { owned += try indirectBlocks(block, depth: depth) }
        }
        return owned
    }

    private func indirectBlocks(_ block: UInt64, depth: Int) throws(DiskError) -> [UInt64] {
        guard block < superblock.blockCount else { throw .corrupt("indirect block \(block)") }
        guard depth > 1 else { return [block] }
        let bytes = try self.block(block)
        var blocks = [block]
        for index in 0 ..< superblock.blockSize / 4 {
            let next = UInt64(try bytes.u32(index * 4))
            if next != 0 { blocks += try indirectBlocks(next, depth: depth - 1) }
        }
        return blocks
    }

    /// A new inode's bytes, written whole: type and permissions, owner, times (creation included), links, size, block
    /// pointers, and the extra space the volume wants.
    func writeNewInode(
        _ number: UInt64,
        kind: NodeKind,
        mode: UInt16,
        owner: (uid: UInt32, gid: UInt32),
        content: NewContent,
        on device: any WritableBlockSource
    ) throws(DiskError) {
        let location = try inodeLocation(number)
        let size = superblock.inodeSize
        var raw = [UInt8](repeating: 0, count: size)
        let isDirectory = kind == .directory
        let type: UInt16 = isDirectory ? 0o040000 : kind == .symlink ? 0o120000 : 0o100000
        Self.put16(type | mode & 0o7777, at: 0x00, in: &raw)
        Self.put16(UInt16(truncatingIfNeeded: owner.uid), at: 0x02, in: &raw)
        Self.put16(UInt16(truncatingIfNeeded: owner.gid), at: 0x18, in: &raw)
        Self.put16(UInt16(truncatingIfNeeded: owner.uid >> 16), at: 0x78, in: &raw)
        Self.put16(UInt16(truncatingIfNeeded: owner.gid >> 16), at: 0x7A, in: &raw)
        Self.put32(UInt32(content.size), at: 0x04, in: &raw)
        Self.put16(isDirectory ? 2 : 1, at: 0x1A, in: &raw)
        Self.put32(content.sectors, at: 0x1C, in: &raw)
        raw.replaceSubrange(0x28 ..< 0x28 + content.blockArea.count, with: content.blockArea)
        let now = clock()
        let (low, extra) = Self.stamp(now)
        Self.put32(UInt32(truncatingIfNeeded: now.nanoseconds) ^ UInt32(truncatingIfNeeded: number), at: 0x64, in: &raw)
        let extraSize = size > 128 ? min(superblock.wantExtraSize, size - 128) : 0
        if extraSize > 0 { Self.put16(UInt16(extraSize), at: 0x80, in: &raw) }
        for (field, extraField) in [(0x08, 0x8C), (0x0C, 0x84), (0x10, 0x88), (0x90, 0x94)] {
            if field >= 128, 128 + extraSize < field + 4 { continue }
            Self.put32(low, at: field, in: &raw)
            if 128 + extraSize >= extraField + 4 { Self.put32(extra, at: extraField, in: &raw) }
        }
        try device.write(at: location.block * UInt64(superblock.blockSize) + UInt64(location.offset), raw)
        blocks.invalidate(location.block)
    }

    /// A new inode's size, 512-byte sectors and 60 bytes of `i_block` (block pointers, or a fast symlink's target).
    struct NewContent {
        var size: UInt64 = 0
        var sectors: UInt32 = 0
        var blockArea: [UInt8] = []

        /// One block of `blockSize` bytes holding `size` of them: a directory's first block, a slow symlink's target.
        static func oneBlock(_ block: UInt64, size: UInt64, blockSize: Int) -> NewContent {
            var area = [UInt8](repeating: 0, count: 4)
            ExtFileSystem.put32(UInt32(block), at: 0, in: &area)
            return NewContent(size: size, sectors: UInt32(blockSize / 512), blockArea: area)
        }
    }
}
