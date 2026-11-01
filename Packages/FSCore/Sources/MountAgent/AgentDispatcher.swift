import AemiProtobuf
public import MountKit
import MountRegistry

/// The agent as a function: request bytes in, reply bytes out, over a `MountService` (roadmap 0039). No XPC here, so every
/// request is tested in one process; the listener is a shell around `handle`. Calls block on the service: the listener runs
/// them on its own queue.
public struct AgentDispatcher: Sendable {
    let service: MountService

    public init(service: MountService) { self.service = service }

    public func handle(_ bytes: [UInt8]) -> [UInt8] {
        let reply: AgentReply
        if let request = try? ProtobufDecoder().decode(AgentRequest.self, fromBytes: bytes) {
            reply = answer(request)
        } else {
            reply = AgentReply(errorCode: AgentReply.Code.malformed.rawValue, error: "the request is not one")
        }
        return (try? ProtobufEncoder().encodeToBytes(reply)) ?? []
    }

    private func answer(_ request: AgentRequest) -> AgentReply {
        guard let operation = AgentRequest.Operation(rawValue: request.operation) else {
            return AgentReply(
                errorCode: AgentReply.Code.unsupported.rawValue,
                error:
                    "operation \(request.operation) is not known to this agent (protocol \(AgentRequest.protocolVersion))"
            )
        }
        do throws(MountError) {
            switch operation {
                case .list:
                    return AgentReply(records: service.records().map { RecordMessage($0) })
                case .mount:
                    let record = try service.mount(
                        source: request.source,
                        kind: MountBackendKind(rawValue: request.kind),
                        at: request.mountPoint
                    )
                    return AgentReply(records: [RecordMessage(record)])
                case .unmount:
                    try service.unmount(id: request.id)
                    return AgentReply()
                case .sweep:
                    let report = service.sweep()
                    return AgentReply(
                        kept: report.kept,
                        unmounted: report.unmounted,
                        forgotten: report.forgotten,
                        skipped: report.skipped,
                        failed: report.failed,
                        unsaved: report.unsaved
                    )
            }
        } catch {
            return Self.reply(error)
        }
    }

    static func reply(_ error: MountError) -> AgentReply {
        switch error {
            case .unavailable(let kind, let reason):
                AgentReply(errorCode: AgentReply.Code.unavailable.rawValue, error: reason, errorKind: kind.rawValue)
            case .noBackend(let kind):
                AgentReply(errorCode: AgentReply.Code.noBackend.rawValue, errorKind: kind.rawValue)
            case .mountPointInUse(let path):
                AgentReply(errorCode: AgentReply.Code.mountPointInUse.rawValue, error: path)
            case .notFound(let id): AgentReply(errorCode: AgentReply.Code.notFound.rawValue, error: id)
            case .unrecognized(let id): AgentReply(errorCode: AgentReply.Code.unrecognized.rawValue, error: id)
            case .backend(let text): AgentReply(errorCode: AgentReply.Code.backend.rawValue, error: text)
            case .registry(let text): AgentReply(errorCode: AgentReply.Code.registry.rawValue, error: text)
            case .agent(let text): AgentReply(errorCode: AgentReply.Code.malformed.rawValue, error: text)
        }
    }
}
