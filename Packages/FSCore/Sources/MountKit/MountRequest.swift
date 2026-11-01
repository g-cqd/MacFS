/// What the service asks a backend to mount: the record's identifier, the image or device, and the mount point.
// @dl:accept -- three strings and a memberwise init, as MountTableEntry: different things that happen to share a shape
public struct MountRequest: Hashable, Sendable {
    public let id: String
    public let source: String
    public let mountPoint: String

    public init(id: String, source: String, mountPoint: String) {
        self.id = id
        self.source = source
        self.mountPoint = mountPoint
    }
}
