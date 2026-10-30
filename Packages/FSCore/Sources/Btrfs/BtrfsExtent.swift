import AemiKernel
import FSCore

/// One `btrfs_file_extent_item`: where a range of a file's bytes lives.
struct BtrfsExtent: Sendable {
    enum Storage: Sendable {
        /// Bytes stored in the item itself, possibly compressed.
        case inline([UInt8])
        /// A range of a (possibly compressed) on-disk extent. `diskAddress` 0 is a hole.
        case regular(diskAddress: UInt64, diskLength: UInt64, offset: UInt64)
        /// Allocated, never written: reads as zeros.
        case preallocated
    }

    let fileOffset: UInt64
    /// Bytes of the file this extent covers.
    let length: UInt64
    /// Size of the uncompressed extent.
    let decodedSize: UInt64
    let compression: UInt8
    let storage: Storage

    init(fileOffset: UInt64, item: DiskBytes) throws(DiskError) {
        self.fileOffset = fileOffset
        decodedSize = try item.u64(8)
        compression = try item.u8(16)
        guard try item.u8(17) == 0, try item.u16(18) == 0 else { throw .accessDenied("encrypted or encoded extent") }
        switch try item.u8(20) {
            case 0:
                let data = try item.bytes(21, item.count - 21)
                storage = .inline(data)
                length = compression == 0 ? UInt64(data.count) : decodedSize
            case let kind where kind == 1 || kind == 2:
                let address = try item.u64(21)
                storage =
                    kind == 2
                    ? .preallocated
                    : .regular(diskAddress: address, diskLength: try item.u64(29), offset: try item.u64(37))
                length = try item.u64(45)
            case let kind:
                throw .corrupt("file extent type \(kind)")
        }
        guard fileOffset.checkedAdding(length) != nil else {
            throw .corrupt("extent at \(fileOffset) of \(length) bytes")
        }
    }

    var end: UInt64 { fileOffset + length }
}
