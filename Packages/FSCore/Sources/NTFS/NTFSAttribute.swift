import FSCore

/// One attribute of an MFT record: a resident value, or a non-resident extent of runs.
struct NTFSAttribute: Sendable {
    struct NonResident: Sendable {
        let firstVCN: UInt64
        let runs: [DataRun]
        let allocatedSize: UInt64
        let dataSize: UInt64
        let initializedSize: UInt64
        let compressionUnit: UInt8
    }

    /// `ATTR_IS_COMPRESSED`: LZNT1, the only compression NTFS defines; other values of the mask are refused.
    static let compressed: UInt16 = 0x0001
    static let compressionMask: UInt16 = 0x00FF
    static let encrypted: UInt16 = 0x4000

    let type: UInt32
    /// UTF-8; empty for the unnamed stream.
    let name: [UInt8]
    let flags: UInt16
    let value: DiskBytes?
    let nonResident: NonResident?

    /// An attribute from its parts.
    init(type: UInt32, name: [UInt8], flags: UInt16, value: DiskBytes?, nonResident: NonResident?) {
        (self.type, self.name, self.flags, self.value, self.nonResident) = (type, name, flags, value, nonResident)
    }

    /// Parses the attribute at the start of `bytes`, which ends where the record's attributes end.
    init(_ bytes: DiskBytes) throws(DiskError) {
        type = try bytes.u32(0)
        let length = Int(try bytes.u32(4))
        guard length >= 24, length <= bytes.count, length % 8 == 0 else {
            throw .corrupt("attribute of \(length) bytes")
        }
        let body = try bytes.slice(0, length)
        let nameLength = Int(try body.u8(9))
        let nameOffset = Int(try body.u16(10))
        name = nameLength == 0 ? [] : UTF16Name.utf8(try body.slice(nameOffset, 2 * nameLength))
        flags = try body.u16(12)
        if try body.u8(8) == 0 {
            let size = Int(try body.u32(16))
            value = try body.slice(Int(try body.u16(20)), size)
            nonResident = nil
        } else {
            let first = try body.u64(16)
            let last = try body.u64(24)
            let runsAt = Int(try body.u16(32))
            guard runsAt >= 64, runsAt <= length else { throw .corrupt("mapping pairs at \(runsAt)") }
            nonResident = NonResident(
                firstVCN: first, runs: try DataRun.decode(try body.slice(from: runsAt), firstVCN: first, lastVCN: last),
                allocatedSize: try body.u64(40), dataSize: try body.u64(48), initializedSize: try body.u64(56),
                compressionUnit: try body.u8(34))
            value = nil
        }
    }

    /// Size of the attribute's content.
    var size: UInt64 { nonResident?.dataSize ?? UInt64(value?.count ?? 0) }
}
