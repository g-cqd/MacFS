import CFSKernels

/// CRC-32C over the arm64 kernel (three interleaved streams folded with PMULL).
public enum CRC32C {
    /// Raw update: no pre- or post-inversion.
    public static func update(_ crc: UInt32, _ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBufferPointer { unsafe fsk_crc32c_update(crc, $0.baseAddress, $0.count) }
    }

    public static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        update(crc, bytes[...])
    }

    /// The conventional checksum: seed ~0, result inverted (what Btrfs stores).
    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        ~update(~0, bytes)
    }
}
