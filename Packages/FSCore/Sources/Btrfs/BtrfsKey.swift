import FSCore

/// A Btrfs item key. Every item in every tree is ordered by (objectID, type, offset).
struct BtrfsKey: Comparable, Hashable, Sendable {
    static let size = 17

    var objectID: UInt64
    var type: UInt8
    var offset: UInt64

    init(_ objectID: UInt64, _ type: UInt8, _ offset: UInt64) {
        self.objectID = objectID
        self.type = type
        self.offset = offset
    }

    init(_ bytes: DiskBytes, at offset: Int) throws(DiskError) {
        self.objectID = try bytes.u64(offset)
        self.type = try bytes.u8(offset + 8)
        self.offset = try bytes.u64(offset + 9)
    }

    static func < (lhs: BtrfsKey, rhs: BtrfsKey) -> Bool {
        (lhs.objectID, lhs.type, lhs.offset) < (rhs.objectID, rhs.type, rhs.offset)
    }
}
