internal import CFSKernels
import FSCore

/// LZO1X decompression, bounds-checked at every step (after the Linux `lzo1x_decompress_safe`): the `fsk_lzo1x_decompress`
/// kernel (arm64 assembly; its portable C reference elsewhere and in the tests). Every length and distance comes from the
/// disk, so each copy checks the input it reads, the output it may still write (`capacity`) and how far back a match may
/// reach. Tests compare it with liblzo2's output, with an independent Swift decoder on mutated streams, and with the C
/// reference (docs/research/2026-10-30-compression-kernels.md).
enum LZO1X {
    static func decompress(_ input: [UInt8], capacity: Int) throws(DiskError) -> [UInt8] {
        guard capacity >= 0 else { throw .corrupt("lzo: capacity \(capacity)") }
        var output = [UInt8](repeating: 0, count: capacity)
        let written = try output.withUnsafeMutableBufferPointer { (target) throws(DiskError) -> Int in
            try input.withUnsafeBufferPointer { (source) throws(DiskError) -> Int in
                try unsafe decompress(source, into: target)
            }
        }
        return written == capacity ? output : Array(output[0 ..< written])
    }

    /// Decodes `input` into `output` (at most `output.count` bytes) and returns how many were written; bytes of `output` past
    /// that are unspecified (the kernel's word moves may run past a copy, never past the buffer). For the Btrfs framing, which
    /// decodes every sector's segment in place into one extent.
    @unsafe static func decompress(_ input: UnsafeBufferPointer<UInt8>, into output: UnsafeMutableBufferPointer<UInt8>)
        throws(DiskError) -> Int
    {
        guard let from = input.baseAddress else { throw .corrupt("lzo: an empty stream") }
        // A buffer of no bytes may have no address; the kernel needs one, and writes nothing to it.
        var spare: UInt8 = 0
        let result = withUnsafeMutablePointer(to: &spare) { fallback in
            unsafe fsk_lzo1x_decompress(from, input.count, output.baseAddress ?? fallback, output.count)
        }
        guard result >= 0 else { throw .corrupt("lzo: a malformed or overlong stream") }
        return Int(result)
    }
}
