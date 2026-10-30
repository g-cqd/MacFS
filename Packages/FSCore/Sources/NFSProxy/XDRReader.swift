/// Decodes XDR with every length checked against what is left and against the caller's maximum.
public struct XDRReader: Sendable {
    private let bytes: [UInt8]
    private var position = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var remaining: Int { bytes.count - position }

    private mutating func take(_ count: Int) throws(XDRError) -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw .truncated }
        defer { position += count }
        return bytes[position ..< (position + count)]
    }

    public mutating func u32() throws(XDRError) -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    public mutating func u64() throws(XDRError) -> UInt64 {
        UInt64(try u32()) << 32 | UInt64(try u32())
    }

    public mutating func bool() throws(XDRError) -> Bool { try u32() != 0 }

    public mutating func opaque(maximum: Int) throws(XDRError) -> [UInt8] {
        let count = try u32()
        guard count <= UInt32(maximum) else { throw .tooLong }
        return try fixed(Int(count))
    }

    public mutating func fixed(_ count: Int) throws(XDRError) -> [UInt8] {
        let value = Array(try take(count))
        _ = try take((4 - count % 4) % 4)
        return value
    }

    public mutating func string(maximum: Int) throws(XDRError) -> String {
        String(decoding: try opaque(maximum: maximum), as: UTF8.self)
    }
}
