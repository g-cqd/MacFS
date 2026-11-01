/// The attributes a mount path may set (ADR-0018): each nil leaves its attribute as it is. The change time follows any change.
public struct AttributeChanges: Sendable, Equatable {
    /// Permission bits (`0o7777`); the node's type is kept.
    public var mode: UInt16?
    public var uid: UInt32?
    public var gid: UInt32?
    public var accessed: Timestamp?
    public var modified: Timestamp?

    public init(
        mode: UInt16? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        accessed: Timestamp? = nil,
        modified: Timestamp? = nil
    ) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.accessed = accessed
        self.modified = modified
    }
}
