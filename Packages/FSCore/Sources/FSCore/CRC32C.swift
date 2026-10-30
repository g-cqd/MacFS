internal import AemiKernels

/// CRC-32C over aemi's kernel: on arm64 three `crc32cx` streams beside eight PMULL folds in 4 KiB chunks, the folds alone from
/// 256 bytes, `crc32cx` below (ADR-0012).
public enum CRC32C {
    /// Raw update: no pre- or post-inversion.
    public static func update(_ crc: UInt32, _ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return crc }
            return unsafe AemiKernels.crc32c(crc, base, count: buffer.count)
        }
    }

    public static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        update(crc, bytes[...])
    }

    /// The conventional checksum: seed ~0, result inverted (what Btrfs stores).
    public static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        ~update(~0, bytes)
    }
}
