public import FSCore

/// The image a crash could have left: the original bytes with `writes` applied in order, read without copying the image.
public struct CrashState: BlockSource {
    public let name: String
    let original: [UInt8]
    let writes: [Write]

    public var byteCount: UInt64 { UInt64(original.count) }

    public func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard count >= 0, offset <= byteCount, UInt64(count) <= byteCount - offset else {
            throw .io(errno: 5, "read \(count) at \(offset) past \(byteCount)")
        }
        var bytes = Array(original[Int(offset) ..< Int(offset) + count])
        let end = offset + UInt64(count)
        for write in writes {
            let writeEnd = write.offset + UInt64(write.bytes.count)
            guard write.offset < end, writeEnd > offset else { continue }
            let from = max(write.offset, offset)
            let to = min(writeEnd, end)
            bytes.replaceSubrange(
                Int(from - offset) ..< Int(to - offset),
                with: write.bytes[Int(from - write.offset) ..< Int(to - write.offset)]
            )
        }
        return bytes
    }

    /// The whole image, for a checker that needs a file.
    public func image() -> [UInt8] {
        (try? read(at: 0, count: original.count)) ?? original
    }
}
