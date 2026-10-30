/// Encodes XDR (RFC 4506): big-endian 32-bit units, variable data padded to four bytes.
public struct XDRWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func u32(_ value: UInt32) {
        bytes += [
            UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }

    public mutating func u64(_ value: UInt64) {
        u32(UInt32(value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }

    public mutating func bool(_ value: Bool) { u32(value ? 1 : 0) }

    /// Variable-length opaque: a length, the bytes, zero padding.
    public mutating func opaque(_ value: [UInt8]) {
        u32(UInt32(value.count))
        fixed(value)
    }

    /// Fixed-length opaque: the bytes and zero padding, no length.
    public mutating func fixed(_ value: [UInt8]) {
        bytes += value
        bytes += [UInt8](repeating: 0, count: (4 - value.count % 4) % 4)
    }

    public mutating func string(_ value: String) { opaque(Array(value.utf8)) }

    public mutating func append(_ other: XDRWriter) { bytes += other.bytes }
}
