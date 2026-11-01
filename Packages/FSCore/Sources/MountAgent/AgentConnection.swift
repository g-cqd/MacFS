public import MountKit
import XPC

/// The app's connection to the agent: an `AgentClient` over an XPC session that accepts only an agent signed by MacFS's own team.
@available(macOS 26, *)
public enum AgentConnection {
    public static func client(service: String = AgentListener.service) throws(MountError) -> AgentClient {
        let session: XPCSession
        do { session = try XPCSession(machService: service, requirement: .isFromSameTeam()) } catch {
            throw .agent("the agent \(service) cannot be reached: \(error)")
        }
        return AgentClient { bytes in
            let reply: AgentEnvelope = try session.sendSync(AgentEnvelope(bytes: bytes))
            return reply.bytes
        }
    }
}
