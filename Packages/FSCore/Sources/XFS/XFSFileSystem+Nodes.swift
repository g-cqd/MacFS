public import FSCore

extension XFSFileSystem {
    /// A directory's names and parent: from the shortform list, or from every data block (logical offsets below 32 GiB),
    /// each assembled from its extents (a directory block may span several), cached.
    func listing(_ directory: UInt64) throws(DiskError) -> Listing {
        try listings.value(for: directory) { () throws(DiskError) -> Listing in
            let inode = try inode(directory)
            guard inode.kind == .directory else { throw .notDirectory }
            if inode.format == XFSInode.local {
                let (parent, entries) = try XFSDirectory.shortform(
                    inode.dataFork, size: Int(inode.size), fileType: superblock.hasFileType)
                return Listing(parent: parent, entries: entries)
            }
            let blockSize = UInt64(superblock.blockSize)
            let dirBlockBlocks = UInt64(superblock.dirBlockSize) / blockSize
            let leafBlock = XFSDirectory.leafOffset / blockSize
            var starts: [UInt64] = []
            for extent in try extents(inode) {
                var start = extent.logical - extent.logical % dirBlockBlocks
                while start < min(extent.end, leafBlock) {
                    if starts.last != start { starts.append(start) }
                    start += dirBlockBlocks
                }
            }
            guard starts.count <= 1 << 20 else { throw .corrupt("directory \(directory) of \(starts.count) blocks") }
            var entries: [XFSDirectory.Entry] = []
            var parent: UInt64?
            for start in starts {
                let bytes = DiskBytes(try mapped(inode, at: start * blockSize, count: superblock.dirBlockSize))
                if let found = try XFSDirectory.dataBlock(bytes, superblock, directory: directory, into: &entries) {
                    parent = parent ?? found
                }
                guard entries.count <= 1 << 22 else { throw .corrupt("directory \(directory) has too many entries") }
            }
            return Listing(parent: parent ?? rootID, entries: entries)
        }
    }

    public func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        guard let entry = try listing(directory).entries.first(where: { $0.name == name }) else { throw .notFound }
        // @dl:accept -- each reader maps its own directory entries to DirectoryEntry; the fields happen to share names
        return DirectoryEntry(name: entry.name, id: entry.inode, kind: try kind(of: entry), nextCookie: 0)
    }

    public func entries(of directory: UInt64, from cookie: UInt64, limit: Int) throws(DiskError) -> [DirectoryEntry] {
        let entries = try listing(directory).entries
        // @dl:accept -- each reader maps its own directory entries to DirectoryEntry; the fields happen to share names
        return try DirectoryPage.page(count: entries.count, from: cookie, limit: limit) {
            (position) throws(DiskError) in
            let entry = entries[position]
            return DirectoryEntry(
                name: entry.name, id: entry.inode, kind: try kind(of: entry), nextCookie: UInt64(position + 1))
        }
    }

    /// The entry's type, or the inode's when the volume does not record types in its directories.
    private func kind(of entry: XFSDirectory.Entry) throws(DiskError) -> NodeKind {
        if let kind = XFSDirectory.kind(entry.type) { return kind }
        return try inode(entry.inode).kind
    }

    public func attributes(of id: UInt64) throws(DiskError) -> NodeAttributes {
        let inode = try inode(id)
        let parent = inode.kind == .directory && id != rootID ? try listing(id).parent : rootID
        var attributes = NodeAttributes(id: id, parent: parent, kind: inode.kind)
        attributes.permissions = inode.mode & 0o7777
        attributes.uid = inode.uid
        attributes.gid = inode.gid
        attributes.linkCount = inode.linkCount
        attributes.size = inode.size
        attributes.allocatedSize = inode.blocks * UInt64(superblock.blockSize)
        attributes.accessed = try inode.time(32)
        attributes.modified = try inode.time(40)
        attributes.changed = try inode.time(48)
        attributes.created = try inode.time(144)
        return attributes
    }

    public func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        let inode = try inode(id)
        guard inode.kind == .regular else { throw inode.kind == .directory ? .isDirectory : .notFound }
        guard offset < inode.size, count > 0 else { return [] }
        let length = Int(min(UInt64(count), inode.size - offset))
        if inode.format == XFSInode.local { return try inode.dataFork.bytes(Int(offset), length) }
        return try mapped(inode, at: offset, count: length)
    }

    /// A symlink's target: in the inode, or in remote blocks (on v5 each with a 56-byte `XSLM` header and a checksum).
    public func readLink(_ id: UInt64) throws(DiskError) -> [UInt8] {
        let inode = try inode(id)
        let size = Int(clamping: inode.size)
        guard inode.kind == .symlink, (1 ... 1024).contains(size) else {
            throw inode.kind == .symlink ? .corrupt("symlink of \(size) bytes") : .notSymlink
        }
        if inode.format == XFSInode.local { return try inode.dataFork.bytes(0, size) }
        var target: [UInt8] = []
        for extent in try extents(inode) {
            for index in 0 ..< extent.count where target.count < size {
                let bytes = try block(extent.physical + index)
                guard try bytes.be32(0) == 0x5853_4C4D else {
                    throw .corrupt("symlink \(id): a block without its magic")
                }
                try XFSChecksum.verify(bytes, at: 12, "symlink \(id): block")
                let (offset, length) = (Int(try bytes.be32(4)), Int(try bytes.be32(8)))
                guard offset == target.count, try bytes.be64(32) == id else {
                    throw .corrupt("symlink \(id): a block out of place")
                }
                target += try bytes.bytes(56, min(length, size - target.count))
            }
        }
        guard target.count == size else { throw .corrupt("symlink \(id): \(target.count) of \(size) bytes") }
        return target
    }
}
