internal import CFSKernels
import FSCore

/// LZNT1 decompression ([MS-XCA] 2.5), as ntfs-3g's `ntfs_decompress` reads it, bounds-checked at every step: the
/// `fsk_lznt1_decompress` kernel (arm64 assembly; the portable C reference elsewhere, and in the tests).
///
/// A compression unit's data is a run of chunks, each decoding into its own 4 KiB of output. A chunk starts with a 16-bit header:
/// the low 12 bits are its size in bytes minus 3 (header included), bit 15 says it is compressed. A stored chunk holds 4,096
/// raw bytes. A compressed one is groups of a flag byte and eight tokens, low bit first: 0 a literal byte, 1 a 16-bit phrase
/// (offset back, length) whose split moves with the position in the chunk: 12 bits of length (minus 3) and 4 of offset (minus
/// 1) up to position 16, one bit moving from length to offset each time the position doubles. A chunk that decodes short is
/// zero-filled to its 4 KiB; a zero header, or the input's end, ends the unit, whose remainder is zero.
enum LZNT1 {
    /// Decodes one compression unit's `input` into exactly `capacity` bytes.
    static func decompress(_ input: [UInt8], capacity: Int) throws(DiskError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: capacity)
        try output.withUnsafeMutableBufferPointer { (target) throws(DiskError) in
            try unsafe decompress(input, into: target)
        }
        return output
    }

    /// Decodes one compression unit's `input` into all of `target`, which must stay valid for the call.
    @unsafe static func decompress(_ input: [UInt8], into target: UnsafeMutableBufferPointer<UInt8>) throws(DiskError) {
        guard let output = target.baseAddress else { return }
        let status = input.withUnsafeBufferPointer { source in
            guard let from = source.baseAddress else {
                unsafe output.update(repeating: 0, count: target.count)
                return Int32(0)
            }
            return unsafe fsk_lznt1_decompress(from, source.count, output, target.count)
        }
        guard status == 0 else { throw .corrupt("lznt1: a damaged compression unit") }
    }
}
