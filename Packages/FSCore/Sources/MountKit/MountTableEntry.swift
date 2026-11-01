/// One line of the system's mount table (`getmntinfo`): where, from what, and of which type.
public struct MountTableEntry: Hashable, Sendable {
    public let mountPoint: String
    public let mountedFrom: String
    public let type: String

    public init(mountPoint: String, mountedFrom: String, type: String) {
        self.mountPoint = mountPoint
        self.mountedFrom = mountedFrom
        self.type = type
    }
}
