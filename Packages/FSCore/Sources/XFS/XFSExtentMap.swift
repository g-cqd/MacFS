import FSCore

/// A data fork's extents, from its list or its B+tree (`xfs_bmdr_block` in the inode, `xfs_btree_block` below it).
enum XFSExtentMap {
    static func extents(
        _ inode: XFSInode, _ superblock: XFSSuperblock, readBlock: (UInt64) throws(DiskError) -> DiskBytes
    ) throws(DiskError) -> [XFSExtent] {
        var extents: [XFSExtent] = []
        switch inode.format {
            case XFSInode.extents:
                guard inode.extentCount <= UInt64(inode.dataFork.count / 16) else {
                    throw .corrupt("inode \(inode.number): \(inode.extentCount) extents in its fork")
                }
                for index in 0 ..< Int(inode.extentCount) {
                    extents.append(try XFSExtent.decode(inode.dataFork, 16 * index, superblock))
                }
            case XFSInode.btree:
                let root = inode.dataFork
                let (level, count) = (Int(try root.be16(0)), Int(try root.be16(2)))
                let slots = (root.count - 4) / 16
                guard level >= 1, level <= 9, count >= 1, count <= slots else {
                    throw .corrupt("inode \(inode.number): B+tree root of level \(level) with \(count) records")
                }
                for index in 0 ..< count {
                    let child = try superblock.diskBlock(try root.be64(4 + 8 * slots + 8 * index))
                    try walk(child, level: level - 1, inode, superblock, readBlock, into: &extents)
                }
            default:
                throw .corrupt("inode \(inode.number): data fork format \(inode.format) holds no extents")
        }
        // In order of offset and apart, as the kernel keeps them (and the reads that follow rely on).
        for (previous, next) in zip(extents, extents.dropFirst()) where previous.end > next.logical {
            throw .corrupt("inode \(inode.number): extents out of order or overlapping at block \(next.logical)")
        }
        return extents
    }

    /// A B+tree block (`BMA3`: a 72-byte header with its checksum and owner), its records or its children.
    private static func walk(
        _ block: UInt64, level: Int, _ inode: XFSInode, _ superblock: XFSSuperblock,
        _ readBlock: (UInt64) throws(DiskError) -> DiskBytes, into extents: inout [XFSExtent]
    ) throws(DiskError) {
        let bytes = try readBlock(block)
        let header = 72
        guard try bytes.be32(0) == 0x424D_4133, Int(try bytes.be16(4)) == level else {
            throw .corrupt("inode \(inode.number): B+tree block \(block) is not one of level \(level)")
        }
        try XFSChecksum.verify(bytes, at: 64, "inode \(inode.number): B+tree block \(block)")
        guard try bytes.be64(56) == inode.number else {
            throw .corrupt("inode \(inode.number): B+tree block \(block) belongs to another inode")
        }
        let count = Int(try bytes.be16(6))
        let slots = (bytes.count - header) / 16
        guard count <= slots, extents.count + count <= 1 << 24 else {
            throw .corrupt("inode \(inode.number): B+tree block \(block) of \(count) records")
        }
        if level == 0 {
            for index in 0 ..< count { extents.append(try XFSExtent.decode(bytes, header + 16 * index, superblock)) }
            return
        }
        for index in 0 ..< count {
            let child = try superblock.diskBlock(try bytes.be64(header + 8 * slots + 8 * index))
            try walk(child, level: level - 1, inode, superblock, readBlock, into: &extents)
        }
    }
}
