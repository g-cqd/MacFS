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

    /// The whole decoded extent behind a compressed or inline item. `verifyData` is false for a NODATASUM inode.
    private func decoded(_ extent: BtrfsExtent, verifyData: Bool) throws(DiskError) -> [UInt8] {
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
                    if verifyData { try dataChecksums.verify(compressed: raw, at: address) }
                    return try BtrfsCompression.decompress(
                        raw, method: extent.compression, size: Int(extent.decodedSize), sectorSize: sector)
                }
            case .preallocated:
                return []
        }
    }

    /// What a read needs of an inode item: its kind, size, and whether its data has checksums.
    struct InodeItem {
        let kind: NodeKind
        let size: UInt64
        let verifiesData: Bool
    }

    func inodeItem(_ id: UInt64) throws(DiskError) -> InodeItem {
        let (tree, inode) = location(id)
        guard let item = try trees.item(root: try treeRoot(tree), BtrfsKey(inode, BtrfsItem.inode, 0)) else {
            throw .notFound
        }
        return InodeItem(
            kind: NodeKind(posixMode: try item.u32(52)), size: try item.u64(16),
            verifiesData: try item.u64(64) & BtrfsItem.noDataChecksumFlag == 0)
    }

    public func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        // The inode item alone (size, mode, flags): attributes(of:) would also look up the parent, on every piece of a read.
        let item = try inodeItem(id)
        guard item.kind != .directory else { throw .isDirectory }
        let size = item.size
        let verifyData = item.verifiesData
        guard offset < size, count > 0 else { return [] }
        let end = min(size, offset + UInt64(count))
        let extents = try extents(id)
        // Plain extents straight from the volume into the result, decoded ones copied in; holes and preallocated ranges
        // stay zero (ReadAssembly).
        return try ReadAssembly.assemble(count: Int(end - offset)) { (pieces) throws(DiskError) in
            for extent in extents where extent.end > offset && extent.fileOffset < end {
                let from = max(offset, extent.fileOffset)
                let to = min(end, extent.end)
                let within = from - extent.fileOffset
                let span = Int(to - from)
                let target = Int(from - offset)
                switch extent.storage {
                    case .preallocated:
                        continue
                    case .regular(let address, let diskLength, let start) where extent.compression == 0:
                        if address == 0 { continue }  // a hole
                        let logical = address + start + within
                        // Read into the result, then checked there: a mismatch throws, and the result is never returned.
                        let checksums = dataChecksums
                        unsafe try pieces.read(
                            trees.source, at: try trees.chunks.physical(logical, length: UInt64(span)), to: target,
                            count: span
                        ) { (bytes) throws(DiskError) in
                            guard verifyData else { return }
                            try unsafe checksums.verify(
                                diskStart: address, diskLength: diskLength, from: logical, count: UInt64(span),
                                read: bytes)
                        }
                    case .regular(_, _, let start):
                        try Self.copy(
                            try decoded(extent, verifyData: verifyData), from: Int(start + within), count: span,
                            into: &pieces, at: target)
                    case .inline:
                        try Self.copy(
                            try decoded(extent, verifyData: verifyData), from: Int(within), count: span, into: &pieces,
                            at: target)
                }
            }
        }
    }

    private static func copy(
        _ data: [UInt8], from: Int, count: Int, into pieces: inout ReadAssembly.Pieces, at target: Int
    ) throws(DiskError) {
        guard from >= 0, from <= data.count else {
            throw .corrupt("extent offset \(from) past its \(data.count) bytes")
        }
        let available = min(count, data.count - from)
        try pieces.copy(data[from ..< (from + available)], to: target)
    }

    public func readLink(_ id: UInt64) throws(DiskError) -> [UInt8] {
        let attributes = try attributes(of: id)
        guard attributes.kind == .symlink else { throw .notSymlink }
        guard attributes.size <= 4096 else { throw .corrupt("symlink of \(attributes.size) bytes") }
        return try read(id, at: 0, count: Int(attributes.size))
    }
}
