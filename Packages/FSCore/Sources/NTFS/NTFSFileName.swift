import FSCore

/// A `$FILE_NAME` value: in a record, and as the key of every directory index entry.
struct NTFSFileName: Sendable {
    static let dosNamespace: UInt8 = 2
    static let directoryFlag: UInt32 = 0x1000_0000
    static let reparseFlag: UInt32 = 0x0400

    let parent: UInt64
    let fileAttributes: UInt32
    /// The reparse tag when `fileAttributes` has the reparse flag.
    let reparseTag: UInt32
    let namespace: UInt8
    let units: [UInt16]
    let name: [UInt8]

    init(_ bytes: DiskBytes) throws(DiskError) {
        parent = try bytes.u64(0) & 0xFFFF_FFFF_FFFF
        fileAttributes = try bytes.u32(0x38)
        reparseTag = try bytes.u32(0x3C)
        let length = Int(try bytes.u8(0x40))
        namespace = try bytes.u8(0x41)
        let raw = try bytes.slice(0x42, 2 * length)
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for index in 0 ..< length { units.append(try raw.u16(2 * index)) }
        self.units = units
        name = UTF16Name.utf8(raw)
    }
}
