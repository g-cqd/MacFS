import AemiProtobuf
public import MountKit
import MountRegistry

/// The app's side of the agent (roadmap 0039): typed calls over a byte transport, which XPC provides in the app and the
/// dispatcher itself provides in tests. Errors come back as the `MountError` the service threw; anything else is `.agent`.
public struct AgentClient: Sendable {
    private let transport: @Sendable ([UInt8], Int32?) throws -> [UInt8]

    /// `transport` carries the request's bytes, and a descriptor beside them when a mount sends the opened image.
    public init(transport: @escaping @Sendable ([UInt8], Int32?) throws -> [UInt8]) { self.transport = transport }

    public func list() throws(MountError) -> [MountRecord] {
        try call(AgentRequest(operation: AgentRequest.Operation.list.rawValue)).records.map(\.record)
    }

    /// Mounts `source`; an empty `mountPoint` lets the agent choose. A `descriptor` of the opened source is sent beside the
    /// request, and the agent owns its copy (the caller keeps and closes its own).
    public func mount(
        source: String,
        kind: MountBackendKind,
        at mountPoint: String,
        descriptor: Int32? = nil
    ) throws(MountError) -> MountRecord {
        let reply = try call(
            AgentRequest(
                operation: AgentRequest.Operation.mount.rawValue,
                source: source,
                kind: kind.rawValue,
                mountPoint: mountPoint
            ),
            descriptor: descriptor
        )
        guard let record = reply.records.first else { throw .agent("the agent mounted nothing it can name") }
        return record.record
    }

    public func unmount(id: String) throws(MountError) {
        _ = try call(AgentRequest(operation: AgentRequest.Operation.unmount.rawValue, id: id))
    }

    public func sweep() throws(MountError) -> SweepReport {
        let reply = try call(AgentRequest(operation: AgentRequest.Operation.sweep.rawValue))
        var report = SweepReport()
        report.kept = reply.kept
        report.unmounted = reply.unmounted
        report.forgotten = reply.forgotten
        report.skipped = reply.skipped
        report.failed = reply.failed
        report.unsaved = reply.unsaved
        return report
    }

    private func call(_ request: AgentRequest, descriptor: Int32? = nil) throws(MountError) -> AgentReply {
        let bytes: [UInt8]
        do { bytes = try transport(try ProtobufEncoder().encodeToBytes(request), descriptor) } catch {
            throw .agent("\(error)")
        }
        guard let reply = try? ProtobufDecoder().decode(AgentReply.self, fromBytes: bytes) else {
            throw .agent("the agent's reply is not one")
        }
        if let error = Self.error(reply) { throw error }
        return reply
    }

    static func error(_ reply: AgentReply) -> MountError? {
        switch AgentReply.Code(rawValue: reply.errorCode) {
            case .ok: nil
            case .unavailable: .unavailable(MountBackendKind(rawValue: reply.errorKind), reply.error)
            case .noBackend: .noBackend(MountBackendKind(rawValue: reply.errorKind))
            case .mountPointInUse: .mountPointInUse(reply.error)
            case .notFound: .notFound(reply.error)
            case .unrecognized: .unrecognized(reply.error)
            case .backend: .backend(reply.error)
            case .registry: .registry(reply.error)
            case .unsupported, .malformed: .agent(reply.error)
            case nil: .agent("error \(reply.errorCode) from a newer agent: \(reply.error)")
        }
    }
}
