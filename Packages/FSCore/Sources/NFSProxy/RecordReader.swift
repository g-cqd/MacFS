/// ONC RPC record marking over TCP (RFC 5531 section 11): fragments with a four-byte header whose top bit
/// marks the last one. Buffers what has arrived and yields whole records, bounded by `maximum`.
public struct RecordReader: Sendable {
    private let maximum: Int
    private var buffer: [UInt8] = []
    private var record: [UInt8] = []

    public init(maximum: Int) {
        self.maximum = maximum
    }

    public mutating func append(_ bytes: [UInt8]) { buffer += bytes }

    /// The next complete record, or nil until one has arrived.
    public mutating func next() throws(XDRError) -> [UInt8]? {
        while buffer.count >= 4 {
            let header = buffer[0 ..< 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            let length = Int(header & 0x7FFF_FFFF)
            guard record.count + length <= maximum else { throw .tooLong }
            guard buffer.count >= 4 + length else { return nil }
            record += buffer[4 ..< (4 + length)]
            buffer.removeFirst(4 + length)
            if header & 0x8000_0000 != 0 {
                defer { record = [] }
                return record
            }
        }
        return nil
    }

    /// One record as a single last fragment.
    public static func frame(_ record: [UInt8]) -> [UInt8] {
        var writer = XDRWriter()
        writer.u32(0x8000_0000 | UInt32(record.count))
        return writer.bytes + record
    }
}
