import FSCore

/// Hashed lookup in XFS directories (roadmap 0037), as the kernel's `xfs_dir_lookup` does it: the name's hash, the hash
/// leaf entries (hash, address) sorted by it, and the data entries they address, whose names settle collisions. The leaf
/// is the single block's tail (block form), one leaf block (`LEAF1`), or the leaves of a node tree (`LEAFN` under `DA3N`
/// blocks, `xfs_da3_node_lookup_int`). A lookup reads a few blocks, not the directory, and builds no listing.
extension XFSFileSystem {
    /// The hash leaf entries of one block: `count` (hash be32, address be32) pairs from `start`, sorted by hash.
    private struct LeafEntries {
        let block: DiskBytes
        let start: Int
        let count: Int

        func hash(_ index: Int) throws(DiskError) -> UInt32 { try block.be32(start + 8 * index) }
        func value(_ index: Int) throws(DiskError) -> UInt32 { try block.be32(start + 8 * index + 4) }

        /// The first entry whose hash is not below `hash`, or `count`.
        func lowerBound(_ hash: UInt32) throws(DiskError) -> Int {
            var (low, high) = (0, count)
            while low < high {
                let middle = (low + high) / 2
                if try self.hash(middle) < hash { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    /// A node on the way down: its entries, the one taken, and its level (leaves are 0).
    private struct Frame {
        let entries: LeafEntries
        let index: Int
        let level: UInt16
    }

    /// What a leaf says of a name: its entry; not there; or not in this leaf, whose last entries are of the name's hash,
    /// so perhaps in the next one.
    private enum Found {
        case entry(XFSDirectory.Entry)
        case absent
        case runGoesOn

        var entry: XFSDirectory.Entry? {
            guard case .entry(let entry) = self else { return nil }
            return entry
        }
    }

    private static let leaf1Magic: UInt16 = 0x3DF1
    private static let leafNMagic: UInt16 = 0x3DFF
    private static let nodeMagic: UInt16 = 0x3EBE

    /// The entry named `name` in `directory`, or nil. "." and ".." are not entries, as in the listing: they have leaf
    /// entries in leaf and node directories, but none in shortform ones, and the kernel resolves them before a lookup.
    func hashedLookup(_ name: [UInt8], in directory: XFSInode) throws(DiskError) -> XFSDirectory.Entry? {
        guard directory.kind == .directory else { throw .notDirectory }
        // Compared byte by byte: array literals here would be built on every lookup.
        guard name.count > 2 || name.contains(where: { $0 != 0x2E }) else { return nil }
        if directory.format == XFSInode.local {
            return try listing(directory.number).entries.first { $0.name == name }
        }
        let hash = XFSDirectoryHash.hash(name)
        let dirBlockSize = superblock.dirBlockSize
        let blockSize = UInt64(superblock.blockSize)
        let dirBlockBlocks = UInt64(dirBlockSize) / blockSize
        let leafBlock = XFSDirectory.leafOffset / blockSize
        // The form, as the kernel's xfs_dir2_format tells it: by where the data fork ends.
        guard let last = try extents(directory).last else { throw .corrupt("directory \(directory.number): no blocks") }
        if last.end == dirBlockBlocks {
            guard directory.size == UInt64(dirBlockSize) else {
                throw .corrupt("directory \(directory.number): one block and \(directory.size) bytes")
            }
            let block = try directoryBlock(directory, at: 0)
            guard try block.be32(0) == XFSDirectory.blockMagic else {
                throw .corrupt("directory \(directory.number): one block that is not a block directory's")
            }
            let count = Int(try block.be32(dirBlockSize - 8))
            let leaf = LeafEntries(block: block, start: dirBlockSize - 8 - 8 * count, count: count)
            return try find(name, hash, in: leaf, directory).entry
        }
        if last.end == leafBlock + dirBlockBlocks {
            let block = try directoryBlock(directory, at: XFSDirectory.leafOffset)
            guard try block.be16(8) == Self.leaf1Magic else {
                throw .corrupt("directory \(directory.number): a leaf directory without its leaf")
            }
            let count = Int(try block.be16(56))
            let bests = Int(try block.be32(dirBlockSize - 4))
            guard 64 + 8 * count <= dirBlockSize - 4 - 2 * bests else {
                throw .corrupt("directory \(directory.number): a leaf of \(count) entries and \(bests) bests")
            }
            return try find(name, hash, in: LeafEntries(block: block, start: 64, count: count), directory).entry
        }
        return try nodeLookup(name, hash, directory)
    }

    /// Down the node tree to the first leaf that may hold `hash`, then on through the next leaves while the run of that
    /// hash goes on: the kernel's `xfs_da3_path_shift` when a leaf's last hash is the one looked for.
    private func nodeLookup(_ name: [UInt8], _ hash: UInt32, _ directory: XFSInode) throws(DiskError)
        -> XFSDirectory.Entry?
    {
        var path: [Frame] = []
        var leaf = try descend(from: XFSDirectory.leafOffset, hash, directory, level: nil, onto: &path)
        while true {
            switch try find(name, hash, in: leaf, directory) {
                case .entry(let entry): return entry
                case .absent: return nil
                case .runGoesOn: break
            }
            // The next leaf: up to the first node with an entry after the one taken, then down its first entries (the
            // first not below `hash`, as every hash after the leaf is not).
            while let top = path.last, top.index + 1 >= top.entries.count { path.removeLast() }
            guard let top = path.popLast() else { return nil }
            path.append(Frame(entries: top.entries, index: top.index + 1, level: top.level))
            let child = UInt64(try top.entries.value(top.index + 1)) * UInt64(superblock.blockSize)
            leaf = try descend(from: child, hash, directory, level: top.level - 1, onto: &path)
        }
    }

    /// From the da block at `offset` (of `level`, when known) down to a leaf: in each node, the first entry whose hash is
    /// not below `hash` (the last one if none), each node one level above the next.
    private func descend(
        from offset: UInt64,
        _ hash: UInt32,
        _ directory: XFSInode,
        level: UInt16?,
        onto path: inout [Frame]
    ) throws(DiskError) -> LeafEntries {
        var offset = offset
        var level = level
        let dirBlockSize = superblock.dirBlockSize
        while true {
            let block = try directoryBlock(directory, at: offset)
            let count = Int(try block.be16(56))
            guard 64 + 8 * count <= dirBlockSize else {
                throw .corrupt("directory \(directory.number): a da block of \(count) entries")
            }
            let entries = LeafEntries(block: block, start: 64, count: count)
            switch try block.be16(8) {
                case Self.leafNMagic:
                    guard level == nil || level == 0 else {
                        throw .corrupt("directory \(directory.number): a leaf where a node of level \(level ?? 0) was")
                    }
                    return entries
                case Self.nodeMagic:
                    let found = try block.be16(58)
                    guard found >= 1, found <= 5, level == nil || found == level, count > 0 else {
                        throw .corrupt("directory \(directory.number): a node of level \(found) and \(count) entries")
                    }
                    let index = min(try entries.lowerBound(hash), count - 1)
                    path.append(Frame(entries: entries, index: index, level: found))
                    level = found - 1
                    offset = UInt64(try entries.value(index)) * UInt64(superblock.blockSize)
                default:
                    throw .corrupt("directory \(directory.number): a da block that is neither node nor leaf")
            }
        }
    }

    /// The entry named `name` among the leaf entries of `hash` (stale ones, of address 0, skipped); when there is none,
    /// whether the run of that hash, not empty, reaches the leaf's end.
    private func find(_ name: [UInt8], _ hash: UInt32, in leaf: LeafEntries, _ directory: XFSInode) throws(DiskError)
        -> Found
    {
        let first = try leaf.lowerBound(hash)
        var index = first
        var current: DataBlock?
        while index < leaf.count, try leaf.hash(index) == hash {
            let address = try leaf.value(index)
            index += 1
            guard address != 0, let entry = try dataEntry(address, named: name, directory, &current) else { continue }
            return .entry(entry)
        }
        return index == leaf.count && index > first ? .runGoesOn : .absent
    }

    /// A data block a run of one hash is reading, kept across its entries, which mostly lie in the same block.
    private struct DataBlock {
        let offset: UInt64
        let block: DiskBytes
        let end: Int
    }

    /// The data entry at `address` (its byte offset in the directory over 8), if it is named `name`.
    private func dataEntry(
        _ address: UInt32,
        named name: [UInt8],
        _ directory: XFSInode,
        _ current: inout DataBlock?
    ) throws(DiskError) -> XFSDirectory.Entry? {
        let offset = UInt64(address) << 3
        let dirBlockSize = UInt64(superblock.dirBlockSize)
        let start = offset - offset % dirBlockSize
        if current?.offset != start {
            let block = try directoryBlock(directory, at: start)
            current = DataBlock(
                offset: start,
                block: block,
                end: try XFSDirectory.entriesEnd(block, directory: directory.number)
            )
        }
        guard let (block, end) = current.map({ ($0.block, $0.end) }) else { return nil }
        let at = Int(offset % dirBlockSize)
        let length = Int(try block.u8(at + 8))
        let typeBytes = superblock.hasFileType ? 1 : 0
        guard at >= 64, try block.be16(at) != 0xFFFF, length > 0, at + 9 + length + typeBytes + 2 <= end else {
            throw .corrupt("directory \(directory.number): a leaf entry addressing no data entry")
        }
        guard length == name.count, block.matches(name, at: at + 9) else { return nil }
        let type: UInt8 = typeBytes == 1 ? try block.u8(at + 9 + length) : 0
        return XFSDirectory.Entry(inode: try block.be64(at), name: name, type: type)
    }

    /// One directory block at a logical byte offset, its magic, checksum and owner checked, cached: data blocks below the
    /// leaf offset, da blocks (node and leaf blocks) above it.
    private func directoryBlock(_ directory: XFSInode, at offset: UInt64) throws(DiskError) -> DiskBytes {
        let key = DirectoryBlock(directory: directory.number, offset: offset)
        return try directoryBlocks.value(for: key) { () throws(DiskError) -> DiskBytes in
            let block = DiskBytes(try mapped(directory, at: offset, count: superblock.dirBlockSize))
            guard offset >= XFSDirectory.leafOffset else {
                try XFSDirectory.check(block, directory: directory.number)
                return block
            }
            let magic = try block.be16(8)
            guard magic == Self.leaf1Magic || magic == Self.leafNMagic || magic == Self.nodeMagic else {
                // @dl:accept -- XFS checks each structure's magic, checksum and owner; the structures differ
                throw .corrupt("directory \(directory.number): a da block without its magic")
            }
            try XFSChecksum.verify(block, at: 12, "directory \(directory.number): da block")
            guard try block.be64(48) == directory.number else {
                throw .corrupt("directory \(directory.number): a da block of another")
            }
            return block
        }
    }
}
