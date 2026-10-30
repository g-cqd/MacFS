import AemiKernel

/// A bounds-checked little-endian view over bytes read from a disk.
///
/// Every offset in an on-disk structure is attacker-controlled, so every load checks its range and
/// throws ``DiskError/corrupt(_:)`` instead of trapping. The loads themselves are Aemi's
/// `loadLE*` (one unaligned load each); this type only adds the check they leave to the caller.
public struct DiskBytes: Sendable {
    public let storage: [UInt8]
    public let start: Int
    public let count: Int

    public init(_ storage: [UInt8]) {
        self.storage = storage
        self.start = 0
        self.count = storage.count
    }

    private init(storage: [UInt8], start: Int, count: Int) {
        self.storage = storage
        self.start = start
        self.count = count
    }

    @inline(__always)
    private func check(_ offset: Int, _ length: Int) throws(DiskError) -> Int {
        guard offset >= 0, length >= 0, let end = offset.checkedAdding(length), end <= count else {
            throw .corrupt("read of \(length) bytes at \(offset) in a \(count)-byte structure")
        }
        return start + offset
    }

    public func slice(_ offset: Int, _ length: Int) throws(DiskError) -> DiskBytes {
        DiskBytes(storage: storage, start: try check(offset, length), count: length)
    }

    public func slice(from offset: Int) throws(DiskError) -> DiskBytes {
        try slice(offset, count - offset)
    }

    public func u8(_ offset: Int) throws(DiskError) -> UInt8 { storage[try check(offset, 1)] }
    // The range is checked first, so the unchecked load below stays inside `storage`.
    public func u16(_ offset: Int) throws(DiskError) -> UInt16 {
        let at = try check(offset, 2)
        return storage.withUnsafeBytes { unsafe $0.loadLE16(at) }
    }
    public func u32(_ offset: Int) throws(DiskError) -> UInt32 {
        let at = try check(offset, 4)
        return storage.withUnsafeBytes { unsafe $0.loadLE32(at) }
    }
    public func u64(_ offset: Int) throws(DiskError) -> UInt64 {
        let at = try check(offset, 8)
        return storage.withUnsafeBytes { unsafe $0.loadLE64(at) }
    }
    public func i8(_ offset: Int) throws(DiskError) -> Int8 { Int8(bitPattern: try u8(offset)) }

    /// A 32-bit value stored as two 16-bit halves (ext's split uid and gid).
    public func u32(low16 low: Int, high16 high: Int) throws(DiskError) -> UInt32 {
        UInt32(try u16(low)) | UInt32(try u16(high)) << 16
    }

    /// A 64-bit value stored as a 32-bit low part and a 16- or 32-bit high part.
    public func u64(low32 low: Int, high16 high: Int) throws(DiskError) -> UInt64 {
        UInt64(try u32(low)) | UInt64(try u16(high)) << 32
    }

    public func u64(low32 low: Int, high32 high: Int) throws(DiskError) -> UInt64 {
        UInt64(try u32(low)) | UInt64(try u32(high)) << 32
    }

    /// A copy of `length` bytes at `offset`.
    public func bytes(_ offset: Int, _ length: Int) throws(DiskError) -> [UInt8] {
        let at = try check(offset, length)
        return Array(storage[at ..< (at + length)])
    }

    /// All bytes of the view, copied.
    public var array: [UInt8] { Array(storage[start ..< (start + count)]) }

    /// Whether `length` bytes at `offset` equal `expected`.
    public func matches(_ expected: [UInt8], at offset: Int) -> Bool {
        guard let at = try? check(offset, expected.count) else { return false }
        return storage[at ..< (at + expected.count)].elementsEqual(expected)
    }
}
