import CFSKernels

/// The NTFS update sequence array ("fixups"): the last two bytes of every 512-byte stride of a
/// multi-sector record are moved into an array in the header, so a torn write is detectable.
public enum UpdateSequence {
    public static let stride = 512

    /// Restores the strides of `record` in place. Throws on a malformed header or a torn write; the
    /// record is then unusable.
    public static func apply(_ record: inout [UInt8], what: String) throws(DiskError) {
        let count = record.count
        let status = record.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return unsafe fsk_ntfs_apply_fixups(base, count, stride)
        }
        switch status {
            case 0: return
            case -2: throw .corrupt("\(what): torn write (update sequence mismatch)")
            default: throw .corrupt("\(what): malformed update sequence array")
        }
    }
}
