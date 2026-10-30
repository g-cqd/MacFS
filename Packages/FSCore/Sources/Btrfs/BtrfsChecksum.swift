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

    /// Bytes of one checksum as stored (the csum tree packs them at this size).
    var size: Int {
        switch self {
            case .crc32c: 4
            case .xxhash64: 8
            case .sha256: 32
        }
    }

    /// The checksum of `bytes`, little-endian, `size` bytes long.
    func digest(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        bytes.withUnsafeBytes { unsafe digest($0) }
    }

    /// The same over memory the caller owns for the call: a read's own result, checked where it landed.
    func digest(_ bytes: UnsafeRawBufferPointer) -> [UInt8] {
        switch self {
            case .crc32c:
                let crc = unsafe CRC32C.update(~0, bytes.assumingMemoryBound(to: UInt8.self))
                return Self.littleEndian(UInt64(~crc), bytes: 4)
            case .xxhash64:
                return Self.littleEndian(unsafe XXH64.hash(bytes), bytes: 8)
            case .sha256:
                return Array(unsafe SHA256.hash(data: bytes))
        }
    }

    /// Whether `stored` (as the csum tree keeps it) is the checksum of `bytes`, without building the digest for the two
    /// integer checksums: 256 sectors a megabyte made the digest's array a cost of its own.
    func matches(_ bytes: UnsafeRawBufferPointer, stored: ArraySlice<UInt8>) -> Bool {
        switch self {
            case .crc32c:
                let raw = unsafe CRC32C.update(~0, bytes.assumingMemoryBound(to: UInt8.self))
                let crc = ~raw
                return stored.count == 4
                    && stored.elementsEqual((0 ..< 4).lazy.map { UInt8(truncatingIfNeeded: crc >> (8 * $0)) })
            case .xxhash64:
                let value = unsafe XXH64.hash(bytes)
                return stored.count == 8
                    && stored.elementsEqual((0 ..< 8).lazy.map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
            case .sha256:
                return stored.elementsEqual(unsafe digest(bytes))
        }
    }

    /// Whether the first bytes of `block` hold the checksum of everything after byte 32.
    func verifies(_ block: DiskBytes) -> Bool {
        let all = block.storage[block.start ..< (block.start + block.count)]
        return all.prefix(size).elementsEqual(digest(all.dropFirst(32)))
    }

    private static func littleEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0 ..< bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
