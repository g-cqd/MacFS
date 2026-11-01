import XPC

/// The agent's XPC shell (roadmap 0039): a Mach service launchd starts on demand, answering only peers signed by MacFS's own
/// team (`isFromSameTeam`), each request handed to the dispatcher.
@available(macOS 26, *)
public final class AgentListener: Sendable {
    /// The service the agent advertises: the app's application group as prefix, which a sandboxed app may look up.
    public static let service = "NP94WB3P75.dev.gcqd.MacFS.agent"

    private let listener: XPCListener

    public init(service: String = AgentListener.service, dispatcher: AgentDispatcher) throws {
        listener = try XPCListener(service: service, requirement: .isFromSameTeam()) { request in
            request.accept { (envelope: AgentEnvelope) -> (any Encodable)? in
                AgentEnvelope(bytes: dispatcher.handle(envelope.bytes))
            }
        }
    }
}
