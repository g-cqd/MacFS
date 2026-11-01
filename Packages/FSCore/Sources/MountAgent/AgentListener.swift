import System
import XPC

/// The agent's XPC shell (roadmap 0039): a Mach service launchd starts on demand, answering only peers signed by MacFS's own
/// team (`isFromSameTeam`). Each message is a dictionary holding the request's bytes and, for a mount, the descriptor of the
/// image the app opened; the dispatcher owns that descriptor from then on.
@available(macOS 27, *)
public final class AgentListener: Sendable {
    /// The service the agent advertises: the app's application group as prefix, which a sandboxed app may look up.
    public static let service = "NP94WB3P75.dev.gcqd.MacFS.agent"
    static let requestKey = "request"
    static let descriptorKey = "descriptor"
    static let replyKey = "reply"

    private let listener: XPCListener

    public init(service: String = AgentListener.service, dispatcher: AgentDispatcher) throws {
        let handler: @Sendable (XPCDictionary) -> XPCDictionary? = { message in Self.answer(message, dispatcher) }
        listener = try XPCListener(service: service, requirement: .isFromSameTeam()) { request in
            request.accept(incomingMessageHandler: handler)
        }
    }

    private static func answer(_ received: XPCDictionary, _ dispatcher: AgentDispatcher) -> XPCDictionary {
        let message = received
        var bytes: [UInt8] = []
        if let span: RawSpan = message[requestKey] { bytes = Array(raw: span) }
        let descriptor: FileDescriptor? = message[descriptorKey]
        let answer = dispatcher.handle(bytes, descriptor: descriptor?.rawValue)
        let reply = XPCDictionary()
        reply.setBytes(answer, for: replyKey)
        return reply
    }
}
