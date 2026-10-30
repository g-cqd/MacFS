/// Bytes addressed by offset: a disk image, a raw device, an FSKit block resource.
///
/// Implementations are safe to call from any thread at once (FSKit and the proxies issue reads
/// concurrently) and keep no cursor.
public protocol BlockSource: Sendable {
    /// Size of the source in bytes.
    var byteCount: UInt64 { get }

    /// Exactly `count` bytes at `offset`. A read past the end throws; nothing is padded.
    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8]

    /// Exactly `buffer.count` bytes at `offset`, written into `buffer`: the same bytes and refusals as `read(at:count:)`, without
    /// the intermediate array where the source can avoid it.
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(DiskError)
}

extension BlockSource {
    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(DiskError) {
        let bytes = try read(at: offset, count: buffer.count)
        bytes.withUnsafeBytes { unsafe buffer.copyMemory(from: $0) }
    }
}
