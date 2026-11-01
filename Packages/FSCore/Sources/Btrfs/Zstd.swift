internal import CFSKernels
import FSCore

/// zstd frames (RFC 8878) through the `fsk_zstd_decompress_frame` kernel (Sources/CFSKernels/zstd.c, roadmap 0013): every
/// bound checked, the content checksum verified when the frame has one, dictionaries refused. Tested against the zstd CLI's
/// frames, zstd's golden files and its decodecorpus generator (ZstdTests).
enum Zstd {
    /// The first frame of `input` into at most `capacity` bytes, and how many bytes of `input` it took (Btrfs pads an
    /// extent's frame with zeros to its sector).
    static func decompressFrame(_ input: [UInt8], capacity: Int) throws(DiskError) -> (bytes: [UInt8], consumed: Int) {
        var output = [UInt8](repeating: 0, count: max(1, capacity))
        let (produced, consumed) = try output.withUnsafeMutableBufferPointer {
            (target) throws(DiskError) -> (Int, Int) in
            try unsafe frame(input, from: 0, into: target.baseAddress!, capacity: capacity)
        }
        return (Array(output[0 ..< produced]), consumed)
    }

    /// Every frame of `input`, one after another, into at most `capacity` bytes (skippable frames add nothing).
    static func decompress(_ input: [UInt8], capacity: Int) throws(DiskError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: max(1, capacity))
        let produced = try output.withUnsafeMutableBufferPointer { (target) throws(DiskError) -> Int in
            var produced = 0
            var at = 0
            while at < input.count {
                let (bytes, consumed) = try unsafe frame(
                    input,
                    from: at,
                    into: target.baseAddress! + produced,
                    capacity: capacity - produced
                )
                produced += bytes
                at += consumed
            }
            return produced
        }
        return Array(output[0 ..< produced])
    }

    /// One frame of `input` from `start` into `target`, with a workspace of its own.
    @unsafe private static func frame(
        _ input: [UInt8],
        from start: Int,
        into target: UnsafeMutablePointer<UInt8>,
        capacity: Int
    ) throws(DiskError) -> (Int, Int) {
        let workspace = UnsafeMutableRawPointer.allocate(byteCount: fsk_zstd_workspace_size(), alignment: 16)
        defer { unsafe workspace.deallocate() }
        var consumed = 0
        let result = input.withUnsafeBufferPointer { source in
            unsafe fsk_zstd_decompress_frame(
                source.baseAddress! + start,
                source.count - start,
                target,
                capacity,
                workspace,
                &consumed
            )
        }
        if result == -2 { throw .unsupported("zstd frames that need a dictionary") }
        guard result >= 0, consumed > 0 else { throw .corrupt("zstd: a malformed frame") }
        return (Int(result), consumed)
    }
}
