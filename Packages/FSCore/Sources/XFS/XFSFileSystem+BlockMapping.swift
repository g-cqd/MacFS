public import FSCore

/// Where a file's bytes lie, for kernel-offloaded I/O (roadmap 0018): its extents, the gaps between them and its unwritten
/// extents as zero. A file whose data fork is local (in the inode) or on the realtime device is not mapped.
extension XFSFileSystem: BlockMapping {
    public func isMappable(_ id: UInt64) throws(DiskError) -> Bool {
        let inode = try inode(id)
        // @dl:accept -- each reader's block map starts the same way; the mapping itself is the format's
        return inode.kind == .regular && inode.format != XFSInode.local && !inode.isRealtime
    }

    public func blockMap(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange] {
        try requireMappable(id)
        let inode = try inode(id)
        let block = UInt64(superblock.blockSize)
        var ranges: [MappedRange] = []
        var next: UInt64 = 0
        for extent in try extents(inode) {
            if extent.logical > next {
                ranges.append(
                    MappedRange(logical: next * block, length: (extent.logical - next) * block, physical: nil)
                )
            }
            ranges.append(
                MappedRange(
                    logical: extent.logical * block,
                    length: extent.count * block,
                    physical: extent.unwritten ? nil : extent.physical * block
                )
            )
            next = extent.end
        }
        let last = (inode.size + block - 1) / block
        if last > next {
            ranges.append(MappedRange(logical: next * block, length: (last - next) * block, physical: nil))
        }
        return MappedRange.clip(ranges, offset: offset, length: length, size: inode.size, unit: block)
    }
}
