public import AemiIO
import AemiKernel
import CFSKernels
import Darwin

/// A ``BlockSource`` over a file descriptor: a disk image, or a raw disk device.
///
/// Raw devices (`/dev/rdiskN`) only accept transfers that start and end on a sector boundary, so
/// reads are widened to `alignment` and trimmed. Image files have an alignment of 1.
public final class FileBlockSource: BlockSource {
    public var byteCount: UInt64 { reader.byteCount }
    public var alignment: Int { reader.alignment }
    private let reader: AlignedReader

    /// Opens `path` read-only.
    public convenience init(path: String) throws(DiskError) {
        let file: PosixFile
        do { file = try PosixFile(path: path, mode: .readOnly) } catch {
            throw .io(errno: error.errno, "open \(path)")
        }
        try self.init(file: file)
    }

    /// Wraps an open descriptor, for one that `authopen` or FSKit handed over.
    public init(file: PosixFile) throws(DiskError) {
        var info = stat()
        guard unsafe fstat(file.fileDescriptor, &info) == 0 else { throw .io(errno: errno, "fstat") }
        let kind = info.st_mode & S_IFMT
        if kind == S_IFCHR || kind == S_IFBLK {
            var blockSize: UInt32 = 0
            var blockCount: UInt64 = 0
            guard unsafe fsk_device_geometry(file.fileDescriptor, &blockSize, &blockCount) == 0, blockSize > 0,
                let size = blockCount.checkedMultiplied(by: UInt64(blockSize))
            else { throw .io(errno: errno, "device geometry") }
            reader = AlignedReader(byteCount: size, alignment: Int(blockSize), raw: Self.transfer(file))
        } else {
            reader = AlignedReader(byteCount: UInt64(max(0, info.st_size)), alignment: 1, raw: Self.transfer(file))
        }
    }

    private static func transfer(_ file: PosixFile) -> AlignedReader.RawRead {
        { (offset, count) throws(DiskError) in
            var buffer = [UInt8](repeating: 0, count: count)
            let failure: IOError? = buffer.withUnsafeMutableBytes { raw in
                do throws(IOError) {
                    try unsafe file.pread(into: raw, at: Int(offset))
                    return nil
                } catch {
                    return error
                }
            }
            if let failure { throw .io(errno: failure.errno, "pread \(count) at \(offset)") }
            return buffer
        }
    }

    public func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        try reader.read(at: offset, count: count)
    }
}
