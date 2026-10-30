public import FSCore

extension BtrfsFileSystem {
    /// The file's extents in file order, cached per node.
    func extents(_ id: UInt64) throws(DiskError) -> [BtrfsExtent] {
        try extentCache.value(for: id) { () throws(DiskError) -> [BtrfsExtent] in
            let (tree, inode) = location(id)
            let items = try trees.items(
                root: try treeRoot(tree), from: BtrfsKey(inode, BtrfsItem.extentData, 0),
                to: BtrfsKey(inode, BtrfsItem.extentData, .max))
            var extents: [BtrfsExtent] = []
            for item in items { extents.append(try BtrfsExtent(fileOffset: item.key.offset, item: item.data)) }
            return extents
        }
    }

    /// The whole decoded extent behind a compressed or inline item.
    private func decoded(_ extent: BtrfsExtent) throws(DiskError) -> [UInt8] {
        let sector = trees.superblock.sectorSize
        switch extent.storage {
            case .inline(let data):
                return try BtrfsCompression.decompress(
                    data, method: extent.compression, size: Int(extent.decodedSize), sectorSize: sector)
            case .regular(let address, let length, _):
                return try decodedCache.value(for: address) { () throws(DiskError) -> [UInt8] in
                    guard length <= 1 << 20 else { throw .corrupt("compressed extent of \(length) bytes") }
                    let physical = try trees.chunks.physical(address, length: length)
                    let raw = try trees.source.read(at: physical, count: Int(length))
                    return try BtrfsCompression.decompress(
                        raw, method: extent.compression, size: Int(extent.decodedSize), sectorSize: sector)
                }
            case .preallocated:
                return []
        }
    }

    public func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        let attributes = try attributes(of: id)
        guard attributes.kind != .directory else { throw .isDirectory }
        guard offset < attributes.size, count > 0 else { return [] }
        let end = min(attributes.size, offset + UInt64(count))
        var output = [UInt8](repeating: 0, count: Int(end - offset))
        for extent in try extents(id) where extent.end > offset && extent.fileOffset < end {
            let from = max(offset, extent.fileOffset)
            let to = min(end, extent.end)
            let within = from - extent.fileOffset
            let span = Int(to - from)
            let target = Int(from - offset)
            switch extent.storage {
                case .preallocated:
                    continue
                case .regular(let address, _, let start) where extent.compression == 0:
                    if address == 0 { continue }  // a hole
                    let logical = address + start + within
                    let bytes = try trees.source.read(
                        at: try trees.chunks.physical(logical, length: UInt64(span)), count: span)
                    output.replaceSubrange(target ..< (target + span), with: bytes)
                case .regular(_, _, let start):
                    let data = try decoded(extent)
                    try copy(data, from: Int(start + within), count: span, into: &output, at: target)
                case .inline:
                    try copy(try decoded(extent), from: Int(within), count: span, into: &output, at: target)
            }
        }
        return output
    }

    private func copy(_ data: [UInt8], from: Int, count: Int, into output: inout [UInt8], at target: Int)
        throws(DiskError)
    {
        guard from >= 0, from <= data.count else {
            throw .corrupt("extent offset \(from) past its \(data.count) bytes")
        }
        let available = min(count, data.count - from)
        output.replaceSubrange(target ..< (target + available), with: data[from ..< (from + available)])
    }

    public func readLink(_ id: UInt64) throws(DiskError) -> [UInt8] {
        let attributes = try attributes(of: id)
        guard attributes.kind == .symlink else { throw .notSymlink }
        guard attributes.size <= 4096 else { throw .corrupt("symlink of \(attributes.size) bytes") }
        return try read(id, at: 0, count: Int(attributes.size))
    }
}
