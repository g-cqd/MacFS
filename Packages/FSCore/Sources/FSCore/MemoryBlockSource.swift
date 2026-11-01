import Synchronization

/// Bytes in memory as a device: a test image's copy, or a crash state being built.
public final class MemoryBlockSource: WritableBlockSource {
    private let storage: Mutex<[UInt8]>

    public init(_ bytes: [UInt8]) { storage = Mutex(bytes) }

    public var bytes: [UInt8] { storage.withLock { $0 } }
    public var byteCount: UInt64 { UInt64(storage.withLock(\.count)) }

    public func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        let result: [UInt8]? = storage.withLock { bytes in
            guard let range = Self.range(offset, count, within: bytes.count) else { return nil }
            return Array(bytes[range])
        }
        guard let result else { throw .io(errno: 5, "read \(count) at \(offset) past \(byteCount)") }
        return result
    }

    public func write(at offset: UInt64, _ bytes: [UInt8]) throws(DiskError) {
        let written: Bool = storage.withLock { storage in
            guard let range = Self.range(offset, bytes.count, within: storage.count) else { return false }
            storage.replaceSubrange(range, with: bytes)
            return true
        }
        guard written else { throw .io(errno: 5, "write \(bytes.count) at \(offset) past \(byteCount)") }
    }

    public func flush() throws(DiskError) {}

    private static func range(_ offset: UInt64, _ count: Int, within size: Int) -> Range<Int>? {
        guard count >= 0, offset <= UInt64(size), UInt64(count) <= UInt64(size) - offset else { return nil }
        return Int(offset) ..< Int(offset) + count
    }
}
