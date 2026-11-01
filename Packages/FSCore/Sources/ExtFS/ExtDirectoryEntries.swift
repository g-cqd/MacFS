import FSCore

/// Directory entries edited in one block's bytes (`ext4_dir_entry_2`, roadmap 0026 step 3): a name inserted where an entry's
/// record has room past its own name, or in an emptied slot; a name removed into the entry before it, or emptied when it comes
/// first in its block, as Linux's ext2 does.
enum ExtDirectoryEntries {
    /// The bytes an entry with a name of `count` bytes needs: its header and name, rounded to four.
    static func recordLength(_ count: Int) -> Int { (8 + count + 3) & ~3 }

    /// One record of a block: where it starts, whose it is (0 for an emptied one), its length and its name's length.
    struct Record {
        let cursor: Int
        let inode: UInt32
        let length: Int
        let nameLength: Int
    }

    /// Every record of `block`, in order; a record that runs past the block is corruption.
    static func records(_ block: [UInt8]) throws(DiskError) -> [Record] {
        let view = DiskBytes(block)
        var records: [Record] = []
        var cursor = 0
        while cursor + 8 <= block.count {
            let length = Int(try view.u16(cursor + 4))
            guard length >= 8, cursor + length <= block.count else { throw .corrupt("directory record at \(cursor)") }
            records.append(
                Record(
                    cursor: cursor,
                    inode: try view.u32(cursor),
                    length: length,
                    nameLength: Int(try view.u8(cursor + 6))
                )
            )
            cursor += length
        }
        return records
    }

    /// `block` with an entry for `inode` named `name`, of `type` (the file type byte, under `filetype`), or nil when no
    /// record in it has room.
    static func inserting(
        _ name: [UInt8],
        inode: UInt32,
        type: UInt8,
        into block: [UInt8]
    ) throws(DiskError) -> [UInt8]? {
        let needed = recordLength(name.count)
        var bytes = block
        for record in try records(block) {
            let used = record.inode == 0 ? 0 : recordLength(record.nameLength)
            guard record.length - used >= needed else { continue }
            if used > 0 { ExtFileSystem.put16(UInt16(used), at: record.cursor + 4, in: &bytes) }
            put(name, inode: inode, type: type, length: record.length - used, at: record.cursor + used, in: &bytes)
            return bytes
        }
        return nil
    }

    /// `block` without the entry named `name`, or nil when it is not in this block.
    static func removing(_ name: [UInt8], from block: [UInt8]) throws(DiskError) -> [UInt8]? {
        var bytes = block
        var previous: Record?
        for record in try records(block) {
            if record.inode != 0, record.nameLength == name.count,
                Array(block[record.cursor + 8 ..< record.cursor + 8 + record.nameLength]) == name
            {
                if let previous {
                    ExtFileSystem.put16(UInt16(previous.length + record.length), at: previous.cursor + 4, in: &bytes)
                } else {
                    ExtFileSystem.put32(0, at: record.cursor, in: &bytes)
                }
                return bytes
            }
            previous = record
        }
        return nil
    }

    /// A new directory's first block: `.` for itself, `..` for its parent, the rest in `..`'s record.
    static func firstBlock(of inode: UInt32, parent: UInt32, size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        put([0x2E], inode: inode, type: 2, length: 12, at: 0, in: &bytes)
        put([0x2E, 0x2E], inode: parent, type: 2, length: size - 12, at: 12, in: &bytes)
        return bytes
    }

    /// A directory block with no name: one empty record spanning it.
    static func emptyBlock(size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        ExtFileSystem.put16(UInt16(size), at: 4, in: &bytes)
        return bytes
    }

    private static func put(
        _ name: [UInt8],
        inode: UInt32,
        type: UInt8,
        length: Int,
        at cursor: Int,
        in bytes: inout [UInt8]
    ) {
        ExtFileSystem.put32(inode, at: cursor, in: &bytes)
        ExtFileSystem.put16(UInt16(length), at: cursor + 4, in: &bytes)
        bytes[cursor + 6] = UInt8(name.count)
        bytes[cursor + 7] = type
        bytes.replaceSubrange(cursor + 8 ..< cursor + 8 + name.count, with: name)
    }
}
