/// What the service asks a backend to mount: the record's identifier, the image or device, the mount point, and optionally an
/// open descriptor of the source: the sandboxed app's, so the agent reads what the user chose without opening its path. The
/// backend owns the descriptor once `mount` is called, and closes it when the mount goes or fails.
// @dl:accept -- three strings and a memberwise init, as MountTableEntry: different things that happen to share a shape
public struct MountRequest: Hashable, Sendable {
    public let id: String
    public let source: String
    public let mountPoint: String
    public let descriptor: Int32?

    public init(id: String, source: String, mountPoint: String, descriptor: Int32? = nil) {
        self.id = id
        self.source = source
        self.mountPoint = mountPoint
        self.descriptor = descriptor
    }
}
