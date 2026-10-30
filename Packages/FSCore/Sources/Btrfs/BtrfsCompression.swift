import CFSKernels
import FSCore

/// Decompresses one extent's bytes (`compression` from `btrfs_file_extent_item`).
enum BtrfsCompression {
    static func decompress(_ input: [UInt8], method: UInt8, size: Int, sectorSize: Int) throws(DiskError) -> [UInt8] {
        guard size >= 0, size <= 1 << 20 else { throw .corrupt("compressed extent of \(size) bytes") }
        switch method {
            case 0: return input
            case 1: return try zlib(input, size: size)
            case 2: return try lzo(input, size: size, sectorSize: sectorSize)
            case 3: return try zstd(input, size: size)
            default: throw .corrupt("compression method \(method)")
        }
    }

    /// One zlib stream, as Linux reads it (fs/btrfs/zlib.c): the two-byte header checked and skipped, the rest raw DEFLATE
    /// through MacFS's decoder (`fsk_inflate`, held to the system libz by InflateTests), the Adler-32 trailer not read.
    private static func zlib(_ input: [UInt8], size: Int) throws(DiskError) -> [UInt8] {
        guard input.count > 2, input[0] & 0x0F == 8, (UInt16(input[0]) << 8 | UInt16(input[1])) % 31 == 0,
            input[1] & 0x20 == 0
        else { throw .corrupt("zlib extent without a zlib header") }
        var output = [UInt8](repeating: 0, count: size)
        guard size > 0 else { return output }
        var produced = 0
        let status = unsafe BufferPair.withBases(input, &output) { from, into in
            Int(unsafe fsk_inflate(from + 2, input.count - 2, into, size, &produced))
        }
        guard status == 0 else { throw .corrupt(status == -2 ? "zlib extent ends early" : "malformed zlib extent") }
        // A short result is legal: the tail of a compressed extent past the data is zero.
        return output
    }

    /// One zstd frame, as Linux writes it (fs/btrfs/zstd.c): the frame, then zeros to the end of its sector, which are not
    /// read. A short result is legal, as for zlib: the extent's tail past the data is zero.
    private static func zstd(_ input: [UInt8], size: Int) throws(DiskError) -> [UInt8] {
        var (output, _) = try Zstd.decompressFrame(input, capacity: size)
        if output.count < size { output += [UInt8](repeating: 0, count: size - output.count) }
        return output
    }

    /// Btrfs's LZO framing: a total length, then one LZO1X segment per sector, each preceded by its
    /// length. A segment header never straddles a sector boundary; the gap before it is padding.
    private static func lzo(_ input: [UInt8], size: Int, sectorSize: Int) throws(DiskError) -> [UInt8] {
        let bytes = DiskBytes(input)
        let total = Int(try bytes.u32(0))
        guard total <= input.count, total >= 4 else { throw .corrupt("lzo extent of \(total) bytes in \(input.count)") }
        // Every segment decoded in place into one zeroed extent (no copy per sector); what no segment covers stays zero.
        var output = [UInt8](repeating: 0, count: size)
        var produced = 0
        var cursor = 4
        while cursor < total, produced < size {
            let inSector = sectorSize - cursor % sectorSize
            if inSector < 4 { cursor += inSector }
            guard cursor + 4 <= total else { break }
            let length = Int(try bytes.u32(cursor))
            cursor += 4
            guard length > 0, length <= total - cursor else { throw .corrupt("lzo segment of \(length) bytes") }
            let room = min(sectorSize, size - produced)
            var failure: DiskError?
            let start = cursor
            let decoded = input.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target -> Int in
                    do throws(DiskError) {
                        return try unsafe LZO1X.decompress(
                            UnsafeBufferPointer(rebasing: source[start ..< start + length]),
                            into: UnsafeMutableBufferPointer(rebasing: target[produced ..< produced + room]))
                    } catch {
                        failure = error
                        return 0
                    }
                }
            }
            if let failure { throw failure }
            // Past a short segment's output the kernel's word moves may have left bytes; what no segment covers is zero.
            if decoded < room {
                output.withUnsafeMutableBufferPointer { target in
                    unsafe UnsafeMutableBufferPointer(rebasing: target[produced + decoded ..< produced + room])
                        .update(repeating: 0)
                }
            }
            produced += decoded
            cursor += length
        }
        return output
    }
}
