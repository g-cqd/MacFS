import Dispatch
public import MountKit
import Synchronization
import System
import XPC

/// The app's connection to the agent: an `AgentClient` over an XPC session that accepts only an agent signed by MacFS's own
/// team. Each message is a dictionary: the request's protobuf bytes, and the opened image's descriptor beside them (XPC
/// duplicates it, so the caller still closes its own). Blocks until the reply: call it off the main thread.
@available(macOS 27, *)
public enum AgentConnection {
    public static func client(service: String = AgentListener.service) throws(MountError) -> AgentClient {
        let session: XPCSession
        do { session = try XPCSession(machService: service, requirement: .isFromSameTeam()) } catch {
            throw .agent("the agent \(service) cannot be reached: \(error)")
        }
        return AgentClient { bytes, descriptor in
            var message = XPCDictionary()
            message.setBytes(bytes, for: AgentListener.requestKey)
            if let descriptor { message[AgentListener.descriptorKey] = FileDescriptor(rawValue: descriptor) }
            let outcome = Mutex<Result<[UInt8], MountError>?>(nil)
            let done = DispatchSemaphore(value: 0)
            session.send(message: message) { result in
                var answer: Result<[UInt8], MountError> = .failure(.agent("the agent's reply has no bytes"))
                switch result {
                    case .success(let reply):
                        if let span: RawSpan = reply[AgentListener.replyKey] { answer = .success(Array(raw: span)) }
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

extension Array where Element == UInt8 {
    /// The bytes a span views, copied.
    init(raw span: RawSpan) {
        self = span.withUnsafeBytes { Array($0) }
    }
}
