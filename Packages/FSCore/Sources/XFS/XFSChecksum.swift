import AemiKernel
import FSCore

/// XFS's metadata checksum: CRC-32C (seeded with ~0, inverted at the end) over a structure with its own checksum field
/// counted as zero; stored little-endian.
enum XFSChecksum {
    static func compute(_ bytes: DiskBytes, at field: Int) throws(DiskError) -> UInt32 {
        var crc = CRC32C.update(~0, try bytes.region(0, field))
        crc = CRC32C.update(crc, [0, 0, 0, 0][...])
        crc = CRC32C.update(crc, try bytes.region(field + 4, bytes.count - field - 4))
        return ~crc
    }

    static func verify(_ bytes: DiskBytes, at field: Int, _ what: @autoclosure () -> String) throws(DiskError) {
        guard try compute(bytes, at: field) == (try bytes.u32(field)) else { throw .checksum(what()) }
    }
}
