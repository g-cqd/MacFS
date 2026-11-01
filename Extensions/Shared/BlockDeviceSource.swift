import FSCore
import FSKit

/// A ``BlockSource`` over the block device FSKit hands a module. FSKit transfers whole blocks only,
/// so reads go through ``AlignedReader``.
struct BlockDeviceSource: WritableBlockSource {
    let byteCount: UInt64
    private let reader: AlignedReader
    private let device: Device
    private let alignment: Int

    /// FSKit's resource is not marked Sendable. Its reads are positioned and stateless, and FSKit itself
    /// issues them from several queues, so sharing it across the reader's threads adds nothing new.
    private final class Device: @unchecked Sendable {
        let resource: FSBlockDeviceResource
        init(_ resource: FSBlockDeviceResource) { self.resource = resource }
    }

    init(_ resource: FSBlockDeviceResource) {
        let device = Device(resource)
        self.device = device
        let size = resource.blockSize * resource.blockCount
        byteCount = size
        let alignment = Int(max(resource.blockSize, resource.physicalBlockSize))
        self.alignment = alignment
        reader = AlignedReader(byteCount: size, alignment: alignment) { (offset, count) throws(DiskError) in
            var buffer = [UInt8](repeating: 0, count: count)
            try Self.transfer("read", count, at: offset) {
                try buffer.withUnsafeMutableBytes { raw in
                    try device.resource.read(into: raw, startingAt: off_t(offset), length: count)
                }
            }
            return buffer
        }
    }

    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        try reader.read(at: offset, count: count)
    }

    /// Writes `bytes` at `offset` through FSKit's direct I/O, whole blocks only: the blocks around them are read, patched and
    /// written whole (ADR-0018). Never mixed with FSKit's metadata (buffer cache) calls on the same range, as FSKit requires.
    func write(at offset: UInt64, _ bytes: [UInt8]) throws(DiskError) {
        guard offset <= byteCount, UInt64(bytes.count) <= byteCount - offset else {
            throw .corrupt("write of \(bytes.count) bytes at \(offset) past the end (\(byteCount))")
        }
        guard device.resource.isWritable else { throw .readOnly }
        let unit = UInt64(alignment)
        let start = offset / unit * unit
        let end = (offset + UInt64(bytes.count) + unit - 1) / unit * unit
        var span = try reader.read(at: start, count: Int(end - start))
        span.replaceSubrange(Int(offset - start) ..< Int(offset - start) + bytes.count, with: bytes)
        try Self.transfer("write", span.count, at: start) {
            try span.withUnsafeBytes { raw in
                try device.resource.write(from: raw, startingAt: off_t(start), length: span.count)
            }
        }
    }

    /// One FSKit transfer of `count` bytes: a short one, or FSKit's error, as a ``DiskError``.
    private static func transfer(_ what: String, _ count: Int, at offset: UInt64, _ body: () throws -> Int)
        throws(DiskError)
    {
        do {
            guard try body() == count else { throw DiskError.io(errno: EIO, "short \(what) at \(offset)") }
        } catch let error as DiskError {
            throw error
        } catch {
            throw DiskError.io(errno: Int32((error as NSError).code), "block device \(what) at \(offset)")
        }
    }

    /// FSKit's direct writes return once the device has them; FSKit offers no way to empty the drive's own cache (its only
    /// flush is for the buffer cache, which these writes bypass). So a barrier here is the order writes were issued in, and
    /// a power loss may still lose what the drive held (ADR-0018 names it).
    func flush() throws(DiskError) {}
}
