import Dispatch
public import MountKit
import Synchronization
import System
public import XPC

/// The app's connection to the agent: an `AgentClient` over an XPC session that accepts only an agent signed by MacFS's own
/// team. Each message is a dictionary: the request's protobuf bytes, and the opened image's descriptor beside them (XPC
/// duplicates it, so the caller still closes its own). Blocks until the reply: call it off the main thread.
///
/// A client lives only inside `withClient`, which cancels its session on the way out: XPC traps when an active session is
/// released without being cancelled (diary 2026-11-01-05).
@available(macOS 27, *)
public enum AgentConnection {
    public static func withClient<T>(
        service: String = AgentListener.service,
        _ body: (AgentClient) throws(MountError) -> T
    ) throws(MountError) -> T {
        let session: XPCSession
        do { session = try XPCSession(machService: service, requirement: .isFromSameTeam()) } catch {
            throw .agent("the agent \(service) cannot be reached: \(error)")
        }
        return try use(session, body)
    }

    /// The same over an anonymous listener's endpoint (tests).
    public static func withClient<T>(
        endpoint: XPCEndpoint,
        _ body: (AgentClient) throws(MountError) -> T
    ) throws(MountError) -> T {
        let session: XPCSession
        do { session = try XPCSession(endpoint: endpoint) } catch { throw .agent("\(error)") }
        return try use(session, body)
    }

    private static func use<T>(
        _ session: XPCSession,
        _ body: (AgentClient) throws(MountError) -> T
    ) throws(MountError) -> T {
        defer { session.cancel(reason: "done") }
        return try body(client(over: session))
    }

    private static func client(over session: XPCSession) -> AgentClient {
        AgentClient { bytes, descriptor in
            var message = XPCDictionary()
            message.setBytes(bytes, for: AgentListener.requestKey)
            if let descriptor { message[AgentListener.descriptorKey] = FileDescriptor(rawValue: descriptor) }
            let outcome = Mutex<Result<[UInt8], MountError>?>(nil)
            let done = DispatchSemaphore(value: 0)
            session.send(message: message) { result in
                var answer: Result<[UInt8], MountError> = .failure(.agent("the agent's reply has no bytes"))
                switch result {
                    case .success(let reply):
                        if let bytes = reply.bytes(for: AgentListener.replyKey) { answer = .success(bytes) }
                    case .failure(let error):
                        answer = .failure(.agent("\(error)"))
                }
                outcome.withLock { $0 = answer }
                done.signal()
            }
            done.wait()
            return try outcome.withLock { $0 ?? .failure(.agent("no reply")) }.get()
        }
    }
}
