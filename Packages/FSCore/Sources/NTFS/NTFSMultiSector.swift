import FSCore

/// FILE records and INDX blocks share one framing: a four-byte magic, then the update sequence array.
enum NTFSMultiSector {
    /// `raw` with its fixups applied, after checking that it is a `magic` structure of the expected size.
    static func restore(_ raw: [UInt8], magic: String, size: Int? = nil, what: String) throws(DiskError) -> [UInt8] {
        var raw = raw
        guard size.map({ raw.count == $0 }) ?? true, DiskBytes(raw).matches(Array(magic.utf8), at: 0) else {
            throw .corrupt("\(what) is not a \(magic) structure")
        }
        try UpdateSequence.apply(&raw, what: what)
        return raw
    }
}
