import FSCore

/// Inline data (`inline_data`): the first 60 bytes live in `i_block`, the rest in the in-inode
/// extended attribute `system.data`.
enum ExtInlineData {
    private static let xattrMagic: UInt32 = 0xEA02_0000
    private static let systemIndex: UInt8 = 7

    static func bytes(_ inode: ExtInode) throws(DiskError) -> [UInt8] {
        let head = inode.blockArea.array
        return head + (try systemData(inode) ?? [])
    }

    /// The value of `system.data` among the attributes after the inode's fixed fields.
    private static func systemData(_ inode: ExtInode) throws(DiskError) -> [UInt8]? {
        let start = 128 + inode.extraSize
        guard start + 4 <= inode.raw.count, try inode.raw.u32(start) == xattrMagic else { return nil }
        let region = try inode.raw.slice(from: start + 4)
        var cursor = 0
        // Entries are 4-byte aligned and end with four zero bytes; each is at least 16 bytes.
        while cursor + 16 <= region.count, try region.u32(cursor) != 0 {
            let nameLength = Int(try region.u8(cursor))
            let index = try region.u8(cursor + 1)
            let valueOffset = Int(try region.u16(cursor + 2))
            let valueInode = try region.u32(cursor + 4)
            let valueSize = Int(try region.u32(cursor + 8))
            let name = try region.bytes(cursor + 16, nameLength)
            if index == systemIndex, name == Array("data".utf8) {
                guard valueInode == 0 else { throw .unsupported("inline data in an EA inode") }
                return try region.bytes(valueOffset, valueSize)
            }
            cursor += (16 + nameLength + 3) & ~3
        }
        return nil
    }
}
