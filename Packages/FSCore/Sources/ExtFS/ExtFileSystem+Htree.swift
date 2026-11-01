import FSCore

/// Hashed lookup in an indexed directory (roadmap 0016), as Linux's `dx_probe`, `ext4_htree_next_block` and `ext4_find_entry`
/// do it: hash the name, descend the index to the leaf block holding that hash, scan it, and go on to the next leaf only while
/// it continues the same hash (a collision split across blocks). An index the kernel would call bad (`ERR_BAD_DX_DIR`: an
/// unknown hash, an unexpected limit or count, too many levels) is not followed, and the caller scans the directory, as the
/// kernel falls back to a linear search; a checksum failure is an error.
extension ExtFileSystem {
    enum IndexedLookup {
        case found(ExtDirectoryBlock.Entry)
        case absent
        /// No index to follow: the directory is linear, casefolded, or its index is one the kernel would not follow.
        case notIndexed
    }

    static let casefoldFlag: UInt32 = 0x4000_0000

    /// One level of the descent: an index block, where its entries start, how many it holds, and the one followed.
    struct Frame {
        let node: DiskBytes
        let offset: Int
        let count: Int
        var at: Int

        /// The logical block the followed entry points to (`dx_get_block`: the top four bits are reserved).
        func child() throws(DiskError) -> UInt64 { UInt64(try node.u32(offset + 8 * at + 4) & 0x0FFF_FFFF) }
    }

    /// Whether a directory's blocks form an htree: the inode flag counts only with `dir_index` (`is_dx`).
    func isIndexed(_ directory: ExtInode) -> Bool {
        directory.flags & ExtInode.indexFlag != 0 && superblock.compat & 0x20 != 0
            && directory.flags & ExtInode.inlineDataFlag == 0
    }

    func indexedLookup(_ name: [UInt8], in directory: ExtInode) throws(DiskError) -> IndexedLookup {
        guard isIndexed(directory), directory.flags & Self.casefoldFlag == 0 else { return .notIndexed }
        let runs = try runs(directory)
        let checksumSize = superblock.checksums == nil ? 0 : 8
        let blockSize = superblock.blockSize
        func indexBlock(_ logical: UInt64) throws(DiskError) -> DiskBytes {
            try directoryBlock(logical, of: directory, runs: runs)
        }

        let root = try indexBlock(0)
        let (reserved, hashVersion) = (try root.u32(0x18), try root.u8(0x1C))
        let (infoLength, levels, unusedFlags) = (try root.u8(0x1D), Int(try root.u8(0x1E)), try root.u8(0x1F))
        var version = hashVersion
        if version <= 2, superblock.flags & 2 != 0 { version += 3 }
        let maximumLevels = superblock.incompat & 0x4000 != 0 ? 3 : 2
        guard reserved == 0, infoLength == 8, unusedFlags & 1 == 0, levels < maximumLevels, hashVersion <= 2,
            let hash = ExtDirectoryHash.hash(name, version: version, seed: superblock.hashSeed)?.major
        else { return .notIndexed }

        // One frame per level: the node's bytes, where its entries start, how many, and the one followed.
        var frames: [Frame] = []
        var node = root
        var offset = 32
        var limit = (blockSize - 32 - checksumSize) / 8
        for _ in 0 ... levels {
            let count = Int(try node.u16(offset + 2))
            guard Int(try node.u16(offset)) == limit, count >= 1, count <= limit else { return .notIndexed }
            var (low, high) = (1, count - 1)
            while low <= high {
                let middle = low + (high - low) / 2
                if try node.u32(offset + 8 * middle) > hash { high = middle - 1 } else { low = middle + 1 }
            }
            frames.append(Frame(node: node, offset: offset, count: count, at: low - 1))
            guard frames.count <= levels else { break }
            node = try indexBlock(try frames[frames.count - 1].child())
            offset = 8
            limit = (blockSize - 8 - checksumSize) / 8
        }

        while true {
            guard let last = frames.last else { return .absent }
            let leaf = try last.child()
            var entries: [ExtDirectoryBlock.Entry] = []
            try ExtDirectoryBlock.entries(try indexBlock(leaf), into: &entries)
            if let match = entries.first(where: { $0.name == name }) { return .found(match) }
            // The next leaf in hash order, only if it starts with this same hash (ext4_htree_next_block).
            var level = frames.count - 1
            while frames[level].at + 1 >= frames[level].count {
                guard level > 0 else { return .absent }
                level -= 1
            }
            frames[level].at += 1
            let next = frames[level]
            guard try next.node.u32(next.offset + 8 * next.at) & ~1 == hash else { return .absent }
            for below in level + 1 ..< frames.count {
                let child = try indexBlock(try frames[below - 1].child())
                frames[below] = Frame(node: child, offset: 8, count: Int(try child.u16(8 + 2)), at: 0)
            }
        }
    }

    /// A directory's logical block, checked as its kind requires (index or leaf). A hole is corruption, as in Linux.
    func directoryBlock(_ logical: UInt64, of directory: ExtInode, runs: [ExtRun]) throws(DiskError) -> DiskBytes {
        guard let run = runs.first(where: { $0.logical <= logical && logical < $0.end }), let physical = run.physical
        else { throw .corrupt("directory \(directory.number): no block \(logical)") }
        let bytes = try block(physical + logical - run.logical)
        if let checksums = superblock.checksums, let seed = directory.checksumSeed {
            try checksums.verifyDirectoryBlock(
                bytes,
                directory: directory.number,
                logical: logical,
                seed: seed,
                indexed: isIndexed(directory)
            )
        }
        return bytes
    }
}
