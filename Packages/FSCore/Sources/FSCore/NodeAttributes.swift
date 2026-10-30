/// The attributes of one node. Identifiers are the file system's own and are stable for the life
/// of the mount; the mount layer maps the root to whatever its technology expects.
public struct NodeAttributes: Sendable, Equatable {
    public var id: UInt64
    public var parent: UInt64
    public var kind: NodeKind
    /// Permission bits only (`0o7777`), never the file type.
    public var permissions: UInt16
    public var uid: UInt32
    public var gid: UInt32
    public var linkCount: UInt32
    public var size: UInt64
    public var allocatedSize: UInt64
    public var accessed: Timestamp
    public var modified: Timestamp
    public var changed: Timestamp
    public var created: Timestamp
    public var isHidden: Bool

    public init(id: UInt64, parent: UInt64, kind: NodeKind) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.permissions = kind == .directory ? 0o755 : 0o644
        self.uid = 99
        self.gid = 99
        self.linkCount = 1
        self.size = 0
        self.allocatedSize = 0
        self.accessed = .epoch
        self.modified = .epoch
        self.changed = .epoch
        self.created = .epoch
        self.isHidden = false
    }
}
