import FSCore

/// `sattr3` (RFC 1813 section 2.6): what a SETATTR, CREATE, MKDIR or SYMLINK asks to set.
struct SetAttributes3: Equatable {
    /// `set_atime`/`set_mtime`: unchanged, the server's time, or the client's.
    enum Time: Equatable {
        case unchanged
        case server
        case client(Timestamp)
    }

    var mode: UInt32?
    var uid: UInt32?
    var gid: UInt32?
    var size: UInt64?
    var accessed = Time.unchanged
    var modified = Time.unchanged

    init() {}

    init(_ reader: inout XDRReader) throws(XDRError) {
        if try reader.bool() { mode = try reader.u32() }
        if try reader.bool() { uid = try reader.u32() }
        if try reader.bool() { gid = try reader.u32() }
        if try reader.bool() { size = try reader.u64() }
        accessed = try Self.time(&reader)
        modified = try Self.time(&reader)
    }

    private static func time(_ reader: inout XDRReader) throws(XDRError) -> Time {
        switch try reader.u32() {
            case 0: return .unchanged
            case 1: return .server
            case 2:
                let seconds = try reader.u32()
                let nanoseconds = try reader.u32()
                return .client(Timestamp(seconds: Int64(seconds), nanoseconds: Int32(min(nanoseconds, 999_999_999))))
            default: throw .truncated
        }
    }

    /// The changes other than the size, the server's time being `now`.
    func changes(now: Timestamp) -> AttributeChanges {
        func resolve(_ time: Time) -> Timestamp? {
            switch time {
                case .unchanged: nil
                case .server: now
                case .client(let value): value
            }
        }
        return AttributeChanges(
            mode: mode.map { UInt16(truncatingIfNeeded: $0 & 0o7777) },
            uid: uid,
            gid: gid,
            accessed: resolve(accessed),
            modified: resolve(modified)
        )
    }

    /// Applies the size, then the rest, to the node `id`.
    func apply(to id: UInt64, through writer: any WritableFileSystem) throws(DiskError) {
        if let size { try writer.setSize(id, to: size) }
        let changes = changes(now: .now)
        if changes != AttributeChanges() { try writer.setAttributes(id, changes) }
    }
}
