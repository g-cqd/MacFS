import AemiProtobuf

/// A request to the mount agent (ADR-0015). `operation` is a plain number: an agent that does not know it refuses it by number.
/// Field numbers are never reused. Retired: 1 (a protocol version nothing read: operations are refused by number instead).
@ProtoMessage struct AgentRequest {
    static let protocolVersion: Int32 = 1

    enum Operation: Int32 {
        case list = 0
        case mount = 1
        case unmount = 2
        case sweep = 3
    }

    @ProtoField(2) var operation: Int32 = 0
    // @dl:accept -- protobuf field declarations look alike from one message to the next
    @ProtoField(3) var source: String = ""
    @ProtoField(4) var kind: Int32 = 0
    @ProtoField(5) var mountPoint: String = ""
    @ProtoField(6) var id: String = ""
}
