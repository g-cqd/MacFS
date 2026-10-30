public import FSCore

extension ExtFileSystem {
    /// Every block run of a non-inline inode, cached.
    func runs(_ inode: ExtInode) throws(DiskError) -> [ExtRun] {
        try mappings.value(for: inode.number) { () throws(DiskError) -> [ExtRun] in
            let blockSize = UInt64(superblock.blockSize)
            if inode.flags & ExtInode.extentsFlag != 0 {
                return try ExtExtentTree.runs(inode.blockArea, number: inode.number) {
                    (block) throws(DiskError) -> DiskBytes in
                    let bytes = try self.block(block)
                    if let checksums = superblock.checksums, let seed = inode.checksumSeed {
                        try checksums.verifyExtentBlock(bytes, inode: inode.number, seed: seed)
                    }
                    return bytes
                }
            }
            let count = (inode.size + blockSize - 1) / blockSize
            guard count <= 1 << 32 else { throw .corrupt("inode \(inode.number) of \(inode.size) bytes") }
            return try ExtIndirectMap.runs(inode.blockArea, first: 0, count: count, blockSize: superblock.blockSize) {
                (block) throws(DiskError) -> DiskBytes in try self.block(block)
            }
        }
    }

    /// `count` bytes from `offset` of the inode's content, holes as zeros.
    func content(_ inode: ExtInode, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard inode.flags & ExtInode.encryptedFlag == 0 else { throw .accessDenied("fscrypt-encrypted inode") }
        guard offset < inode.size, count > 0 else { return [] }
        let end = min(inode.size, offset + UInt64(count))
        if inode.flags & ExtInode.inlineDataFlag != 0 {
            let data = try ExtInlineData.bytes(inode)
            let available = UInt64(data.count)
            var output = [UInt8](repeating: 0, count: Int(end - offset))
            if offset < available {
                let copy = Int(min(end, available) - offset)
                output.replaceSubrange(0 ..< copy, with: data[Int(offset) ..< (Int(offset) + copy)])
            }
            return output
        }
        let blockSize = UInt64(superblock.blockSize)
        var output = [UInt8](repeating: 0, count: Int(end - offset))
        for run in try runs(inode) {
            let from = max(offset, run.logical * blockSize)
            let to = min(end, run.end * blockSize)
            guard from < to, let physical = run.physical else { continue }
            let byte = physical * blockSize + (from - run.logical * blockSize)
            let span = Int(to - from)
            let bytes = try source.read(at: byte, count: span)
            let target = Int(from - offset)
            output.replaceSubrange(target ..< (target + span), with: bytes)
        }
        return output
    }

    public func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        let inode = try inode(id)
        guard inode.kind != .directory else { throw .isDirectory }
        return try content(inode, at: offset, count: count)
    }

    public func readLink(_ id: UInt64) throws(DiskError) -> [UInt8] {
        let inode = try inode(id)
        guard inode.kind == .symlink else { throw .notSymlink }
        guard inode.size < 4096 else { throw .corrupt("symlink of \(inode.size) bytes") }
        // A fast symlink keeps its target in i_block and owns no blocks (beyond an xattr block).
        let xattrSectors: UInt64 = inode.xattrBlock != 0 ? UInt64(superblock.blockSize / 512) : 0
        if inode.flags & ExtInode.inlineDataFlag == 0, inode.sectors == xattrSectors, inode.size < 60 {
            return try inode.blockArea.bytes(0, Int(inode.size))
        }
        return try content(inode, at: 0, count: Int(inode.size))
    }
}
