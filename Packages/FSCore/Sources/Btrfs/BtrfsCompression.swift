import Compression
import FSCore

/// Decompresses one extent's bytes (`compression` from `btrfs_file_extent_item`).
enum BtrfsCompression {
    static func decompress(_ input: [UInt8], method: UInt8, size: Int, sectorSize: Int) throws(DiskError) -> [UInt8] {
        guard size >= 0, size <= 1 << 20 else { throw .corrupt("compressed extent of \(size) bytes") }
        switch method {
            case 0: return input
            case 1: return try zlib(input, size: size)
            case 2: return try lzo(input, size: size, sectorSize: sectorSize)
            case 3: throw .unsupported("zstd-compressed extents")
            default: throw .corrupt("compression method \(method)")
        }
    }

    /// One zlib stream. Apple's `COMPRESSION_ZLIB` is raw DEFLATE, so the two-byte zlib header is
    /// checked and skipped; the Adler-32 trailer is left unread.
    private static func zlib(_ input: [UInt8], size: Int) throws(DiskError) -> [UInt8] {
        guard input.count > 2, input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0,
            input[1] & 0x20 == 0
        else { throw .corrupt("zlib extent without a zlib header") }
        var output = [UInt8](repeating: 0, count: size)
        let produced = unsafe BufferPair.withBases(input, &output) { from, into in
            unsafe compression_decode_buffer(into, size, from + 2, input.count - 2, nil, COMPRESSION_ZLIB)
        }
        guard produced <= size else { throw .corrupt("zlib produced more than it was given room for") }
        // A short result is legal: the tail of a compressed extent past the data is zero.
        return output
    }

    /// Btrfs's LZO framing: a total length, then one LZO1X segment per sector, each preceded by its
    /// length. A segment header never straddles a sector boundary; the gap before it is padding.
    private static func lzo(_ input: [UInt8], size: Int, sectorSize: Int) throws(DiskError) -> [UInt8] {
        let bytes = DiskBytes(input)
        let total = Int(try bytes.u32(0))
        guard total <= input.count, total >= 4 else { throw .corrupt("lzo extent of \(total) bytes in \(input.count)") }
        var output: [UInt8] = []
        output.reserveCapacity(size)
        var cursor = 4
        while cursor < total, output.count < size {
            let inSector = sectorSize - cursor % sectorSize
            if inSector < 4 { cursor += inSector }
            guard cursor + 4 <= total else { break }
            let length = Int(try bytes.u32(cursor))
            cursor += 4
            guard length > 0, length <= total - cursor else { throw .corrupt("lzo segment of \(length) bytes") }
            let segment = try bytes.bytes(cursor, length)
            output += try LZO1X.decompress(segment, capacity: min(sectorSize, size - output.count))
            cursor += length
        }
        if output.count < size { output += [UInt8](repeating: 0, count: size - output.count) }
        return output
    }
}
