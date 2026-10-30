internal import AemiKernels

/// Set bits in a byte buffer (aemi's NEON `cnt` kernel). Aemi's `Popcount` counts words; this counts allocation bitmaps,
/// which are megabytes.
public enum BitCount {
    public static func ones(in bytes: [UInt8]) -> UInt64 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt64(unsafe AemiKernels.bitCount(base, count: buffer.count))
        }
    }
}
