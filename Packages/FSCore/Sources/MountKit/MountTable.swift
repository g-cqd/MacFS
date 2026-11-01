/// The system's mount table, behind a seam so the service is tested without mounting anything.
public protocol MountTable: Sendable {
    func entries() -> [MountTableEntry]
    /// `path` as the table spells it (on macOS, `/tmp/x` is mounted as `/private/tmp/x`).
    func canonical(_ path: String) -> String
}
