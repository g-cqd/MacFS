import FSCore

/// One verified tree block (`struct btrfs_header` and what follows it).
struct BtrfsNode: Sendable {
    static let headerSize = 0x65
    static let leafItemSize = 25
    static let keyPointerSize = 33
    /// BTRFS_MAX_LEVEL: a tree is at most eight levels deep.
    static let maximumLevel: UInt8 = 7

    let bytes: DiskBytes
    let level: UInt8
    let count: Int

    /// Checks the header against what the parent promised: where it is, its level, that it belongs
    /// to this file system, and that its checksum holds.
    init(_ raw: [UInt8], at logical: UInt64, superblock: BtrfsSuperblock) throws(DiskError) {
        let bytes = DiskBytes(raw)
        guard superblock.checksum.verifies(bytes) else { throw .checksum("tree block at \(logical)") }
        guard try bytes.u64(0x30) == logical else { throw .corrupt("tree block at \(logical) records another address") }
        guard bytes.matches(superblock.metadataFSID, at: 0x20) else {
            throw .corrupt("tree block at \(logical) belongs to another file system")
        }
        level = try bytes.u8(0x64)
        count = Int(try bytes.u32(0x60))
        guard level <= Self.maximumLevel else { throw .corrupt("tree block at \(logical) has level \(level)") }
        let entry = level == 0 ? Self.leafItemSize : Self.keyPointerSize
        guard Self.headerSize + count * entry <= bytes.count else {
            throw .corrupt("tree block at \(logical) holds \(count) items")
        }
        self.bytes = bytes
    }

    func key(_ index: Int) throws(DiskError) -> BtrfsKey {
        let entry = level == 0 ? Self.leafItemSize : Self.keyPointerSize
        return try BtrfsKey(bytes, at: Self.headerSize + index * entry)
    }

    /// Leaf item `index`: its data, located relative to the end of the header.
    func itemData(_ index: Int) throws(DiskError) -> DiskBytes {
        let at = Self.headerSize + index * Self.leafItemSize
        let offset = Int(try bytes.u32(at + 17))
        let size = Int(try bytes.u32(at + 21))
        return try bytes.slice(Self.headerSize + offset, size)
    }

    /// Internal node `index`: the logical address of the child.
    func child(_ index: Int) throws(DiskError) -> UInt64 {
        try bytes.u64(Self.headerSize + index * Self.keyPointerSize + BtrfsKey.size)
    }
}
