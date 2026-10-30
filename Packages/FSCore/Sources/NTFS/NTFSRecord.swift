import FSCore

/// One FILE record of the MFT, fixups applied, attributes parsed.
struct NTFSRecord: Sendable {
    static let inUse: UInt16 = 0x01
    static let directory: UInt16 = 0x02

    let number: UInt64
    let flags: UInt16
    /// The base record when this one is an extension, else 0.
    let base: UInt64
    var attributes: [NTFSAttribute]

    init(_ raw: [UInt8], number: UInt64) throws(DiskError) {
        let bytes = DiskBytes(try NTFSMultiSector.restore(raw, magic: "FILE", what: "MFT record \(number)"))
        flags = try bytes.u16(0x16)
        base = try bytes.u64(0x20) & 0xFFFF_FFFF_FFFF
        let used = Int(try bytes.u32(0x18))
        guard used <= bytes.count else { throw .corrupt("MFT record \(number) uses \(used) bytes") }
        var cursor = Int(try bytes.u16(0x14))
        var attributes: [NTFSAttribute] = []
        // Each attribute is at least 24 bytes, so the loop ends within the record.
        while cursor + 4 <= used, try bytes.u32(cursor) != NTFSAttributeType.end {
            let attribute = try NTFSAttribute(try bytes.slice(cursor, used - cursor))
            attributes.append(attribute)
            cursor += Int(try bytes.u32(cursor + 4))
        }
        self.number = number
        self.attributes = attributes
    }

    func first(_ type: UInt32, named name: [UInt8] = []) -> NTFSAttribute? {
        attributes.first { $0.type == type && $0.name == name }
    }

    /// Every extent of one attribute, in VCN order (an attribute list can split a stream over records).
    func extents(_ type: UInt32, named name: [UInt8] = []) -> [NTFSAttribute] {
        attributes.filter { $0.type == type && $0.name == name }
            .sorted { ($0.nonResident?.firstVCN ?? 0) < ($1.nonResident?.firstVCN ?? 0) }
    }
}
