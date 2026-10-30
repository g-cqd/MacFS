/// Bytes addressed by offset: a disk image, a raw device, an FSKit block resource.
///
/// Implementations are safe to call from any thread at once (FSKit and the proxies issue reads
/// concurrently) and keep no cursor.
public protocol BlockSource: Sendable {
    /// Size of the source in bytes.
    var byteCount: UInt64 { get }

    /// Exactly `count` bytes at `offset`. A read past the end throws; nothing is padded.
    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8]
}
