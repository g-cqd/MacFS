/// What XPC carries between the app and the agent: the protobuf bytes of one request or reply. XPC's own `Codable` mapping is
/// only this one field, so version skew is protobuf's to handle (ADR-0015).
public struct AgentEnvelope: Codable, Sendable {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = bytes }
}
