import AemiProtobuf
import MountRegistry

/// The agent's reply: records, a sweep's report, or an error as a code with its text (and the backend kind it names).
/// Field numbers are never reused. Retired: none yet.
@ProtoMessage struct AgentReply {
    enum Code: Int32 {
        case ok = 0
        case unavailable = 1
        case noBackend = 2
        case mountPointInUse = 3
        case notFound = 4
        case unrecognized = 5
        case backend = 6
        case registry = 7
        case unsupported = 8
        case malformed = 9
    }

    @ProtoField(1) var records: [RecordMessage] = []
    @ProtoField(2) var errorCode: Int32 = 0
    @ProtoField(3) var error: String = ""
    @ProtoField(4) var errorKind: Int32 = 0
    @ProtoField(5) var kept: [String] = []
    @ProtoField(6) var unmounted: [String] = []
    @ProtoField(7) var forgotten: [String] = []
    @ProtoField(8) var skipped: [String] = []
    @ProtoField(9) var failed: [String] = []
    @ProtoField(10) var unsaved: Bool = false
}
