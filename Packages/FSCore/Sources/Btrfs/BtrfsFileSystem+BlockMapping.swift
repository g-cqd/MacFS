public import FSCore

/// Where a file's bytes lie, for kernel-offloaded I/O (roadmap 0018): plain extents through the chunk map, holes and
/// preallocated extents as zero. A file with any inline or compressed extent stays with `read`. Before the kernel reads a
/// mapped range, its data checksums are verified (once per piece, as `read` does), as Linux verifies a read from the disk.
extension BtrfsFileSystem: BlockMapping {
    public func isMappable(_ id: UInt64) throws(DiskError) -> Bool {
        guard try inodeItem(id).kind == .regular else { return false }
        return try extents(id)
            .allSatisfy { extent in
                switch extent.storage {
                    case .inline: false
                    case .preallocated: true
                    case .regular: extent.compression == 0
                }
            }
    }

    public func blockMap(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange] {
        guard try isMappable(id) else { throw .unsupported("inode \(id) is not stored as its bytes") }
        var ranges: [MappedRange] = []
        for extent in try extents(id) {
            guard case .regular(let address, _, let start) = extent.storage, address != 0 else { continue }
            let physical = try trees.chunks.physical(address + start, length: extent.length)
            ranges.append(MappedRange(logical: extent.fileOffset, length: extent.length, physical: physical))
        }
        return MappedRange.clip(
            ranges, offset: offset, length: length, size: try inodeItem(id).size,
            unit: UInt64(trees.superblock.sectorSize))
    }

    public func prepareMappedRead(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) {
        let item = try inodeItem(id)
        guard item.verifiesData else { return }
        let end = offset + length
        for extent in try extents(id) where extent.end > offset && extent.fileOffset < end {
            guard case .regular(let address, let diskLength, let start) = extent.storage, address != 0 else { continue }
            let from = max(offset, extent.fileOffset)
            let to = min(end, extent.end)
            unsafe try dataChecksums.verify(
                diskStart: address, diskLength: diskLength, from: address + start + from - extent.fileOffset,
                count: to - from)
        }
    }
}
