/// Where the registry persists. The protobuf store in its checked envelope lives outside MountKit (ADR-0015), so the FSKit
/// extensions that link MountKit do not carry it.
public protocol MountRegistryStore: Sendable {
    func load() throws(MountError) -> [MountRecord]
    func save(_ records: [MountRecord]) throws(MountError)
}
