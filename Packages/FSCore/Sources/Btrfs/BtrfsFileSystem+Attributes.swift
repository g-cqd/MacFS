public import FSCore

extension BtrfsFileSystem {
    public func attributes(of id: UInt64) throws(DiskError) -> NodeAttributes {
        let (tree, inode) = location(id)
        let root = try treeRoot(tree)
        guard let item = try trees.item(root: root, BtrfsKey(inode, BtrfsItem.inode, 0)) else { throw .notFound }
        let mode = try item.u32(52)
        var attributes = NodeAttributes(
            id: id,
            parent: try parent(of: id, tree: tree, inode: inode, root: root),
            kind: NodeKind(posixMode: mode)
        )
        attributes.permissions = UInt16(mode & 0o7777)
        attributes.size = try item.u64(16)
        attributes.allocatedSize = try item.u64(24)
        attributes.linkCount = try item.u32(40)
        attributes.uid = try item.u32(44)
        attributes.gid = try item.u32(48)
        attributes.accessed = try Self.time(item, 112)
        attributes.changed = try Self.time(item, 124)
        attributes.modified = try Self.time(item, 136)
        attributes.created = try Self.time(item, 148)
        return attributes
    }

    private func parent(of id: UInt64, tree: UInt64, inode: UInt64, root: UInt64) throws(DiskError) -> UInt64 {
        if id == rootID { return rootID }
        if inode == BtrfsItem.firstFreeObject {
            // The root of a nested subvolume: its parent directory is named by the root tree's backref.
            let backrefs = try trees.items(
                root: trees.superblock.rootTree,
                from: BtrfsKey(tree, BtrfsItem.rootBackref, 0),
                to: BtrfsKey(tree, BtrfsItem.rootBackref, .max),
                limit: 1
            )
            guard let backref = backrefs.first else { return rootID }
            return (try? identifier(tree: backref.key.offset, inode: try backref.data.u64(0))) ?? rootID
        }
        let refs = try trees.items(
            root: root,
            from: BtrfsKey(inode, BtrfsItem.inodeRef, 0),
            to: BtrfsKey(inode, BtrfsItem.inodeRef, .max),
            limit: 1
        )
        guard let ref = refs.first else { return rootID }
        return try identifier(tree: tree, inode: ref.key.offset)
    }

    private static func time(_ item: DiskBytes, _ offset: Int) throws(DiskError) -> Timestamp {
        let seconds = try item.u64(offset)
        let nanoseconds = try item.u32(offset + 8)
        return Timestamp(seconds: Int64(bitPattern: seconds), nanoseconds: Int32(clamping: nanoseconds % 1_000_000_000))
    }
}
