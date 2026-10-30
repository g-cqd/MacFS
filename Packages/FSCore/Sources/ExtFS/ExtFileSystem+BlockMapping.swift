public import FSCore

/// Where a file's bytes lie, for kernel-offloaded I/O (roadmap 0018): the extent tree's or the indirect blocks' runs, holes
/// and unwritten extents as zero. Inline data and fscrypt contents are not stored as their bytes, so they stay with `read`.
extension ExtFileSystem: BlockMapping {
    public func isMappable(_ id: UInt64) throws(DiskError) -> Bool {
        let inode = try inode(id)
        return inode.kind == .regular && inode.flags & (ExtInode.inlineDataFlag | ExtInode.encryptedFlag) == 0
    }

    public func blockMap(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange] {
        let inode = try inode(id)
        guard try isMappable(id) else { throw .unsupported("inode \(id) is not stored as its bytes") }
        let block = UInt64(superblock.blockSize)
        let ranges = try runs(inode)
            .map { run in
                MappedRange(
                    logical: run.logical * block, length: run.count * block, physical: run.physical.map { $0 * block })
            }
        return MappedRange.clip(ranges, offset: offset, length: length, size: inode.size, unit: block)
    }
}
