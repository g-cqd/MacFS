public import FSCore

extension BtrfsFileSystem {
    /// The node an entry of `tree` points at: an inode of the same tree, or the root of a subvolume.
    private func entry(_ item: BtrfsDirectoryItem, tree: UInt64, nextCookie: UInt64) throws(DiskError) -> DirectoryEntry
    {
        let id: UInt64
        if item.location.type == BtrfsItem.rootItem {
            id = try identifier(tree: item.location.objectID, inode: BtrfsItem.firstFreeObject)
        } else {
            id = try identifier(tree: tree, inode: item.location.objectID)
        }
        return DirectoryEntry(name: item.name, id: id, kind: item.kind, nextCookie: nextCookie)
    }

    public func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        let (tree, inode) = location(directory)
        guard try attributes(of: directory).kind == .directory else { throw .notDirectory }
        let hash = UInt64(CRC32C.update(~1, name))
        guard let item = try trees.item(root: try treeRoot(tree), BtrfsKey(inode, BtrfsItem.dirItem, hash)),
            let match = try BtrfsDirectoryItem.all(in: item).first(where: { $0.name == name })
        else { throw .notFound }
        return try entry(match, tree: tree, nextCookie: 0)
    }

    /// Entries in DIR_INDEX order, which is creation order and stable. A cookie is the next index.
    public func entries(of directory: UInt64, from cookie: UInt64, limit: Int) throws(DiskError) -> [DirectoryEntry] {
        let (tree, inode) = location(directory)
        guard try attributes(of: directory).kind == .directory else { throw .notDirectory }
        let items = try trees.items(
            root: try treeRoot(tree), from: BtrfsKey(inode, BtrfsItem.dirIndex, cookie),
            to: BtrfsKey(inode, BtrfsItem.dirIndex, .max), limit: limit)
        var listed: [DirectoryEntry] = []
        for item in items {
            guard let first = try BtrfsDirectoryItem.all(in: item.data).first else { continue }
            listed.append(try entry(first, tree: tree, nextCookie: item.key.offset + 1))
        }
        return listed
    }
}
