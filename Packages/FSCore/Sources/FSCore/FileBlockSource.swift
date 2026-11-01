public import AemiIO
import AemiKernel
import CFSKernels
import Darwin

/// A ``BlockSource`` over a file descriptor: a disk image, or a raw disk device.
///
/// Raw devices (`/dev/rdiskN`) only accept transfers that start and end on a sector boundary, so
/// reads are widened to `alignment` and trimmed. Image files have an alignment of 1.
public final class FileBlockSource: WritableBlockSource {
    public var byteCount: UInt64 { reader.byteCount }
    public var alignment: Int { reader.alignment }
    private let reader: AlignedReader
    /// Image files (alignment 1) are read straight into the caller's memory; devices go through the aligned reader.
    private let direct: PosixFile?
    /// The descriptor writes go to; nil when opened read-only.
    private let writable: PosixFile?

    /// Opens `path`, read-only unless `writable`.
    public convenience init(path: String, writable: Bool = false) throws(DiskError) {
        let file: PosixFile
        do { file = try PosixFile(path: path, mode: writable ? .readWrite(create: false) : .readOnly) } catch {
            throw .io(errno: error.errno, "open \(path)")
        }
        try self.init(file: file, writable: writable)
    }

    /// Wraps an open descriptor, for one that `authopen` or FSKit handed over.
    public init(file: PosixFile, writable: Bool = false) throws(DiskError) {
        self.writable = writable ? file : nil
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
            direct = nil
        } else {
            reader = AlignedReader(byteCount: UInt64(max(0, info.st_size)), alignment: 1, raw: Self.transfer(file))
            direct = file
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

    public func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(DiskError) {
        guard let direct else {
            let bytes = try reader.read(at: offset, count: buffer.count)
            bytes.withUnsafeBytes { unsafe buffer.copyMemory(from: $0) }
            return
        }
        guard offset <= byteCount, UInt64(buffer.count) <= byteCount - offset else {
            throw .corrupt("read of \(buffer.count) bytes at \(offset) past the end (\(byteCount))")
        }
        do throws(IOError) { try unsafe direct.pread(into: buffer, at: Int(offset)) } catch {
            throw .io(errno: error.errno, "pread \(buffer.count) at \(offset)")
        }
    }

    /// Writes `bytes` at `offset`; on a device (alignment above 1), the sectors around them are read, patched and written whole.
    public func write(at offset: UInt64, _ bytes: [UInt8]) throws(DiskError) {
        guard let writable else { throw .readOnly }
        guard offset <= byteCount, UInt64(bytes.count) <= byteCount - offset else {
            throw .corrupt("write of \(bytes.count) bytes at \(offset) past the end (\(byteCount))")
        }
        let alignment = UInt64(reader.alignment)
        let start = offset / alignment * alignment
        let end = (offset + UInt64(bytes.count) + alignment - 1) / alignment * alignment
        var span =
            start == offset && end == offset + UInt64(bytes.count)
            ? bytes : try reader.read(at: start, count: Int(end - start))
        if span.count != bytes.count {
            span.replaceSubrange(Int(offset - start) ..< Int(offset - start) + bytes.count, with: bytes)
        }
        let failure: IOError? = span.withUnsafeBytes { raw in
            do throws(IOError) {
                try unsafe writable.pwrite(raw, at: Int(start))
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw .io(errno: failure.errno, "pwrite \(span.count) at \(start)") }
    }

    /// F_FULLFSYNC: the writes are on the medium, past the drive's cache, once this returns.
    public func flush() throws(DiskError) {
        guard let writable else { return }
        do throws(IOError) { try writable.sync(.full) } catch { throw .io(errno: error.errno, "F_FULLFSYNC") }
    }
}
