import AemiProtobuf
import Darwin
import Foundation
public import MountKit
import MountRegistry

/// The agent as a function: request bytes in, reply bytes out, over a `MountService` (roadmap 0039). No XPC here, so every
/// request is tested in one process; the listener is a shell around `handle`. Calls block on the service: the listener runs
/// them on its own queue.
public struct AgentDispatcher: Sendable {
    let service: MountService
    /// Where the agent puts a mount whose request names no point: the app is sandboxed, and its home is a container.
    let mounts: String

    public init(service: MountService, mounts: String) {
        self.service = service
        self.mounts = mounts
    }

    /// Answers `bytes`. A `descriptor` travels with a mount request (the image the app opened); with any other request, or
    /// one that is refused before it reaches the service, it is closed here.
    public func handle(_ bytes: [UInt8], descriptor: Int32?) -> [UInt8] {
        let reply: AgentReply
        if let request = try? ProtobufDecoder().decode(AgentRequest.self, fromBytes: bytes) {
            if request.operation != AgentRequest.Operation.mount.rawValue, let descriptor { close(descriptor) }
            reply = answer(request, descriptor: descriptor)
        } else {
            if let descriptor { close(descriptor) }
            reply = AgentReply(errorCode: AgentReply.Code.malformed.rawValue, error: "the request is not one")
        }
        return (try? ProtobufEncoder().encodeToBytes(reply)) ?? []
    }

    private func answer(_ request: AgentRequest, descriptor: Int32?) -> AgentReply {
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
                    let point = request.mountPoint.isEmpty ? freeMountPoint(for: request.source) : request.mountPoint
                    let record = try service.mount(
                        source: request.source,
                        kind: MountBackendKind(rawValue: request.kind),
                        at: point,
                        descriptor: descriptor,
                        writable: request.writable
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

    /// `<mounts>/<image name>`, or `<image name> 2`, 3… when a record or a directory holds it already.
    func freeMountPoint(for source: String) -> String {
        let file = source.split(separator: "/").last.map(String.init) ?? "Volume"
        let dot = file.lastIndex(of: ".").flatMap { $0 == file.startIndex ? nil : $0 }
        let name = dot.map { String(file[..<$0]) } ?? file
        let taken = Set(service.records().map(\.mountPoint))
        var candidate = "\(mounts)/\(name)"
        var number = 1
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: candidate) {
            number += 1
            candidate = "\(mounts)/\(name) \(number)"
        }
        return candidate
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
