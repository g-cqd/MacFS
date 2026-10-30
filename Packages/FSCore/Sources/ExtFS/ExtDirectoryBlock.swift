import FSCore

/// Directory entries (`ext4_dir_entry_2`) in one block or inline buffer. Htree interior blocks hold one
/// empty entry spanning the block and checksum tails are entries with inode 0, so a linear scan of
/// every block of a directory sees exactly its names.
enum ExtDirectoryBlock {
    struct Entry: Sendable {
        let inode: UInt64
        let type: UInt8
        let name: [UInt8]
    }

    static func entries(_ block: DiskBytes, into entries: inout [Entry]) throws(DiskError) {
        var cursor = 0
        while cursor + 8 <= block.count {
            let inode = try block.u32(cursor)
            let length = Int(try block.u16(cursor + 4))
            let nameLength = Int(try block.u8(cursor + 6))
            let type = try block.u8(cursor + 7)
            guard length >= 8, length % 4 == 0, cursor + length <= block.count, 8 + nameLength <= length else {
                throw .corrupt("directory entry of \(length) bytes at \(cursor)")
            }
            if inode != 0 {
                let name = try block.bytes(cursor + 8, nameLength)
                if name != [0x2E], name != [0x2E, 0x2E] {
                    entries.append(Entry(inode: UInt64(inode), type: type, name: name))
                }
            }
            cursor += length
        }
    }

    static func kind(_ type: UInt8) -> NodeKind { NodeKind(linuxDirectoryType: type) }
}
