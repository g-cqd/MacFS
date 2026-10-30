import FSCore

/// XFS directory entries: the shortform list in the inode, and the entries of data blocks (block, leaf and node directories
/// all keep their names in data blocks; the leaf and node blocks only index them by hash).
enum XFSDirectory {
    struct Entry: Sendable {
        let inode: UInt64
        let name: [UInt8]
        /// The entry's file type (XFS_DIR3_FT_*), 0 when the volume does not record it.
        let type: UInt8
    }

    /// The logical offset of the first leaf block (XFS_DIR2_LEAF_OFFSET): data blocks lie below it.
    static let leafOffset: UInt64 = 1 << 35

    /// A shortform directory (`xfs_dir2_sf_hdr` and its entries): the parent, then each entry's name, type and inode.
    static func shortform(_ fork: DiskBytes, size: Int, fileType: Bool) throws(DiskError) -> (parent: UInt64, [Entry]) {
        let count = Int(try fork.u8(0))
        let wide = try fork.u8(1) != 0
        let inodeBytes = wide ? 8 : 4
        func inode(_ at: Int) throws(DiskError) -> UInt64 { wide ? try fork.be64(at) : UInt64(try fork.be32(at)) }
        guard size <= fork.count else {
            throw .corrupt("shortform directory of \(size) bytes in a \(fork.count)-byte fork")
        }
        let parent = try inode(2)
        var cursor = 2 + inodeBytes
        var entries: [Entry] = []
        for _ in 0 ..< count {
            let length = Int(try fork.u8(cursor))
            let name = try fork.bytes(cursor + 3, length)
            cursor += 3 + length
            var type: UInt8 = 0
            if fileType {
                type = try fork.u8(cursor)
                cursor += 1
            }
            guard length > 0, cursor + inodeBytes <= size else {
                throw .corrupt("shortform directory entry past its end")
            }
            entries.append(Entry(inode: try inode(cursor), name: name, type: type))
            cursor += inodeBytes
        }
        return (parent, entries)
    }

    /// One data block's entries (`XDB3` in a single-block directory, `XDD3` otherwise); "." and ".." are left out, ".."
    /// returned apart.
    static func dataBlock(
        _ block: DiskBytes, _ superblock: XFSSuperblock, directory: UInt64, into entries: inout [Entry]
    ) throws(DiskError) -> UInt64? {
        try check(block, directory: directory)
        let end = try entriesEnd(block, directory: directory)
        var cursor = 64
        var parent: UInt64?
        while cursor < end {
            if try block.be16(cursor) == 0xFFFF {
                let length = Int(try block.be16(cursor + 2))
                guard length >= 8, length % 8 == 0 else {
                    throw .corrupt("directory \(directory): free space of \(length)")
                }
                cursor += length
                continue
            }
            let inode = try block.be64(cursor)
            let length = Int(try block.u8(cursor + 8))
            let name = try block.bytes(cursor + 9, length)
            let type: UInt8 = superblock.hasFileType ? try block.u8(cursor + 9 + length) : 0
            let size = (8 + 1 + length + (superblock.hasFileType ? 1 : 0) + 2 + 7) & ~7
            guard length > 0, cursor + size <= end else {
                throw .corrupt("directory \(directory): an entry past its block")
            }
            if name == [0x2E, 0x2E] {
                parent = inode
            } else if name != [0x2E] {
                entries.append(Entry(inode: inode, name: name, type: type))
            }
            cursor += size
        }
        return parent
    }

    /// The magic of a single-block directory's block (`XDB3`); the blocks of larger ones are `XDD3`.
    static let blockMagic: UInt32 = 0x5844_4233

    /// A data block's magic, checksum and owner.
    static func check(_ block: DiskBytes, directory: UInt64) throws(DiskError) {
        let magic = try block.be32(0)
        guard magic == blockMagic || magic == 0x5844_4433 else {
            // @dl:accept -- XFS checks each structure's magic, checksum and owner; the structures differ
            throw .corrupt("directory \(directory): a data block without its magic")
        }
        try XFSChecksum.verify(block, at: 4, "directory \(directory): data block")
        guard try block.be64(40) == directory else { throw .corrupt("directory \(directory): a block of another") }
    }

    /// Where a checked data block's entries end: at the block's end, or in a single-block directory at its hash leaf
    /// entries and their tail (count, stale), which close the block.
    static func entriesEnd(_ block: DiskBytes, directory: UInt64) throws(DiskError) -> Int {
        guard try block.be32(0) == blockMagic else { return block.count }
        let end = block.count - 8 - 8 * Int(try block.be32(block.count - 8))
        guard end >= 64 else { throw .corrupt("directory \(directory): a leaf of \(end) bytes") }
        return end
    }

    /// XFS_DIR3_FT_*: regular, directory, character and block devices, FIFO, socket, symlink.
    static func kind(_ type: UInt8) -> NodeKind? {
        switch type {
            case 1: .regular
            case 2: .directory
            case 3: .characterDevice
            case 4: .blockDevice
            case 5: .fifo
            case 6: .socket
            case 7: .symlink
            default: nil
        }
    }
}
