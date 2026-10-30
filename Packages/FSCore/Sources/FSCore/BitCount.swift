import CFSKernels

/// Set bits in a byte buffer (NEON `cnt`). Aemi's `Popcount` counts words; this counts allocation
/// bitmaps, which are megabytes.
public enum BitCount {
    public static func ones(in bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBufferPointer { unsafe fsk_popcount($0.baseAddress, $0.count) }
    }
}
