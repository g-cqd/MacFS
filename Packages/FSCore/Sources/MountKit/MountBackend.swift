/// One mount technology behind the seam (ADR-0013). Calls block: the service runs them off any cooperative pool.
public protocol MountBackend: Sendable {
    var kind: MountBackendKind { get }

    func availability(of source: String) -> MountAvailability

    /// Mounts, and returns what the mount table will show as the mount's source.
    func mount(_ request: MountRequest) throws(MountError) -> String

    func unmount(_ record: MountRecord) throws(MountError)

    /// The mount of `record` is gone without this backend unmounting it (the kernel removed a dead proxy's mount, the user
    /// ran `umount`): clean up what the mount left, such as an empty mount point it made.
    func forget(_ record: MountRecord)

    /// Whether this process still serves the mount (a proxy's server is alive); always true for a backend that needs no server.
    func isServing(_ record: MountRecord) -> Bool

    /// Whether a mount table entry is of the kind this backend makes, which a pending record's sweep needs to prove ownership.
    func claims(_ entry: MountTableEntry) -> Bool
}
