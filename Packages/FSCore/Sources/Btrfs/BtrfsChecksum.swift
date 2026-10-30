import AemiKernel
import CryptoKit
import FSCore

/// The checksum a file system was formatted with. Every metadata block and the superblock carry one
/// in their first 32 bytes, over the bytes that follow.
enum BtrfsChecksum: Sendable {
    case crc32c
    case xxhash64
    case sha256

    init(type: UInt16) throws(DiskError) {
        switch type {
            case 0: self = .crc32c
            case 1: self = .xxhash64
            case 2: self = .sha256
            case 3: throw .unsupported("BLAKE2b checksums")
            default: throw .corrupt("unknown checksum type \(type)")
        }
    }

    /// Whether the first bytes of `block` hold the checksum of everything after byte 32.
    func verifies(_ block: DiskBytes) -> Bool {
        let all = block.storage[block.start ..< (block.start + block.count)]
        let covered = all.dropFirst(32)
        let stored = all.prefix(32)
        switch self {
            case .crc32c:
                let value = CRC32C.checksum(covered)
                return stored.prefix(4).elementsEqual(Self.littleEndian(UInt64(value), bytes: 4))
            case .xxhash64:
                let value = XXH64.hash(Array(covered))
                return stored.prefix(8).elementsEqual(Self.littleEndian(value, bytes: 8))
            case .sha256:
                return stored.elementsEqual(SHA256.hash(data: Array(covered)))
        }
    }

    private static func littleEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0 ..< bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
