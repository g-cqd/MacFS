import FSCore
import FSKit

/// A ``BlockSource`` over the block device FSKit hands a module. FSKit transfers whole blocks only,
/// so reads go through ``AlignedReader``.
struct BlockDeviceSource: BlockSource {
    let byteCount: UInt64
    private let reader: AlignedReader

    /// FSKit's resource is not marked Sendable. Its reads are positioned and stateless, and FSKit itself
    /// issues them from several queues, so sharing it across the reader's threads adds nothing new.
    private final class Device: @unchecked Sendable {
        let resource: FSBlockDeviceResource
        init(_ resource: FSBlockDeviceResource) { self.resource = resource }
    }

    init(_ resource: FSBlockDeviceResource) {
        let device = Device(resource)
        let size = resource.blockSize * resource.blockCount
        byteCount = size
        let alignment = Int(max(resource.blockSize, resource.physicalBlockSize))
        reader = AlignedReader(byteCount: size, alignment: alignment) { (offset, count) throws(DiskError) in
            var buffer = [UInt8](repeating: 0, count: count)
            do {
                let transferred = try buffer.withUnsafeMutableBytes { raw in
                    try device.resource.read(into: raw, startingAt: off_t(offset), length: count)
                }
                guard transferred == count else { throw DiskError.io(errno: EIO, "short read at \(offset)") }
            } catch let error as DiskError {
                throw error
            } catch {
                throw DiskError.io(errno: Int32((error as NSError).code), "block device read at \(offset)")
            }
            return buffer
        }
    }

    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        try reader.read(at: offset, count: count)
    }
}
