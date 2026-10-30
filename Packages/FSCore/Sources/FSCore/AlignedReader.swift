import AemiKernel

/// Widens reads to a device's alignment and trims the result.
///
/// Raw disks (`/dev/rdiskN`) and FSKit block resources only transfer whole sectors. Every reader
/// above asks for arbitrary ranges, so this is the one place that rounds. Range checks happen
/// before any transfer: a read past the end never reaches the device.
public struct AlignedReader: Sendable {
    public typealias RawRead = @Sendable (UInt64, Int) throws(DiskError) -> [UInt8]

    public let byteCount: UInt64
    public let alignment: Int
    private let raw: RawRead

    public init(byteCount: UInt64, alignment: Int, raw: @escaping RawRead) {
        precondition(alignment > 0 && alignment.nonzeroBitCount == 1, "alignment must be a power of two")
        self.byteCount = byteCount
        self.alignment = alignment
        self.raw = raw
    }

    public func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard count >= 0, let end = offset.checkedAdding(UInt64(count)), end <= byteCount else {
            throw .corrupt("read of \(count) bytes at \(offset) past the end (\(byteCount))")
        }
        if count == 0 { return [] }
        let align = UInt64(alignment)
        let first = offset & ~(align - 1)
        let last = min((end + align - 1) & ~(align - 1), byteCount)
        let bytes = try raw(first, Int(last - first))
        guard bytes.count == Int(last - first) else { throw .io(errno: 5, "short transfer at \(first)") }
        let skip = Int(offset - first)
        return skip == 0 && bytes.count == count ? bytes : Array(bytes[skip ..< (skip + count)])
    }
}
