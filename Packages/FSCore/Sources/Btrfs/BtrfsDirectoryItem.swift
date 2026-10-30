import FSCore

/// One entry of a `btrfs_dir_item`. DIR_ITEM items pack several entries (names whose hashes collide);
/// DIR_INDEX items hold one.
struct BtrfsDirectoryItem: Sendable {
    let location: BtrfsKey
    let type: UInt8
    let name: [UInt8]

    static func all(in item: DiskBytes) throws(DiskError) -> [BtrfsDirectoryItem] {
        var entries: [BtrfsDirectoryItem] = []
        var cursor = 0
        while cursor < item.count {
            let location = try BtrfsKey(item, at: cursor)
            let dataLength = Int(try item.u16(cursor + 25))
            let nameLength = Int(try item.u16(cursor + 27))
            let type = try item.u8(cursor + 29)
            let name = try item.bytes(cursor + 30, nameLength)
            entries.append(BtrfsDirectoryItem(location: location, type: type, name: name))
            cursor += 30 + nameLength + dataLength
        }
        return entries
    }

    var kind: NodeKind { NodeKind(linuxDirectoryType: type) }
}
