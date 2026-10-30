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
            let runs = try runs(inode)
            for run in runs where run.physical != nil {
                for index in 0 ..< run.count {
                    let bytes = try directoryBlock(run.logical + index, of: inode, runs: runs)
                    try ExtDirectoryBlock.entries(bytes, into: &entries)
                    guard entries.count <= 1 << 22 else {
                        throw .corrupt("directory \(directory) has too many entries")
                    }
                }
            }
            return entries
        }
    }

    /// A name in a directory: from its listing when cached, else through its index when it has one (a few blocks), else
    /// from its listing, read and cached.
    public func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        var found: ExtDirectoryBlock.Entry?
        if let cached = listings[directory] {
            found = cached.first { $0.name == name }
        } else {
            let inode = try inode(directory)
            guard inode.kind == .directory else { throw .notDirectory }
            switch try indexedLookup(name, in: inode) {
                case .found(let entry): found = entry
                case .absent: found = nil
                case .notIndexed: found = try listing(directory).first { $0.name == name }
            }
        }
        guard let entry = found else { throw .notFound }
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
