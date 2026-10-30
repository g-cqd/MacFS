public import FSCore

extension ExtFileSystem {
    /// Every name of a directory, in on-disk order, cached.
    func listing(_ directory: UInt64) throws(DiskError) -> [ExtDirectoryBlock.Entry] {
        try listings.value(for: directory) { () throws(DiskError) -> [ExtDirectoryBlock.Entry] in
            let inode = try inode(directory)
            guard inode.kind == .directory else { throw .notDirectory }
            var entries: [ExtDirectoryBlock.Entry] = []
            if inode.flags & ExtInode.inlineDataFlag != 0 {
                // Inline directories start with the parent's inode number instead of "." and "..".
                let data = DiskBytes(try ExtInlineData.bytes(inode))
                try ExtDirectoryBlock.entries(try data.slice(4, 56), into: &entries)
                if data.count > 60 { try ExtDirectoryBlock.entries(try data.slice(from: 60), into: &entries) }
                return entries
            }
            let indexed = inode.flags & ExtInode.indexFlag != 0
            for run in try runs(inode) {
                guard let physical = run.physical else { continue }
                for index in 0 ..< run.count {
                    let bytes = try block(physical + index)
                    if let checksums = superblock.checksums, let seed = inode.checksumSeed {
                        try checksums.verifyDirectoryBlock(bytes, directory: directory, seed: seed, indexed: indexed)
                    }
                    try ExtDirectoryBlock.entries(bytes, into: &entries)
                    guard entries.count <= 1 << 22 else {
                        throw .corrupt("directory \(directory) has too many entries")
                    }
                }
            }
            return entries
        }
    }

    public func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        guard let entry = try listing(directory).first(where: { $0.name == name }) else { throw .notFound }
        return DirectoryEntry(
            name: entry.name, id: entry.inode, kind: ExtDirectoryBlock.kind(entry.type), nextCookie: 0)
    }

    public func entries(of directory: UInt64, from cookie: UInt64, limit: Int) throws(DiskError) -> [DirectoryEntry] {
        let entries = try listing(directory)
        guard cookie < UInt64(entries.count) else { return [] }
        let start = Int(cookie)
        return (start ..< min(entries.count, start + max(0, limit)))
            .map { position in
                let entry = entries[position]
                return DirectoryEntry(
                    name: entry.name, id: entry.inode, kind: ExtDirectoryBlock.kind(entry.type),
                    nextCookie: UInt64(position + 1))
            }
    }

    public func attributes(of id: UInt64) throws(DiskError) -> NodeAttributes {
        let inode = try inode(id)
        var parent = rootID
        if inode.kind == .directory, id != rootID {
            parent = (try? parentOf(inode)) ?? rootID
        }
        var attributes = NodeAttributes(id: id, parent: parent, kind: inode.kind)
        attributes.permissions = inode.mode & 0o7777
        attributes.uid = inode.uid
        attributes.gid = inode.gid
        attributes.linkCount = UInt32(inode.linkCount)
        attributes.size = inode.size
        let unit: UInt64 = inode.flags & ExtInode.hugeFileFlag != 0 ? UInt64(superblock.blockSize) : 512
        attributes.allocatedSize = inode.sectors * unit
        attributes.accessed = try inode.time(0x08, extra: 0x8C)
        attributes.changed = try inode.time(0x0C, extra: 0x84)
        attributes.modified = try inode.time(0x10, extra: 0x88)
        // i_crtime exists only where the extra space covers it (Linux's EXT4_FITS_IN_INODE); 128-byte inodes have none.
        if 128 + inode.extraSize >= 0x94 { attributes.created = try inode.time(0x90, extra: 0x94) }
        return attributes
    }

    /// The ".." entry: the first block's second entry, or the first word of an inline directory.
    private func parentOf(_ inode: ExtInode) throws(DiskError) -> UInt64 {
        if inode.flags & ExtInode.inlineDataFlag != 0 { return UInt64(try inode.blockArea.u32(0)) }
        guard let first = try runs(inode).first, let physical = first.physical else { return rootID }
        let block = try block(physical)
        let dotLength = Int(try block.u16(4))
        return UInt64(try block.u32(dotLength))
    }
}
