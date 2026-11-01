/// One mount as the registry holds it: written `pending` before the mount is attempted, `mounted` once it is up, removed once it
/// is gone (ADR-0013). `mountedFrom` is what the mount table shows as its source, which is how the sweep proves it is ours.
public struct MountRecord: Hashable, Sendable {
    public enum State: Hashable, Sendable, CustomStringConvertible {
        case pending
        case mounted
        case unrecognized(Int32)

        public init(rawValue: Int32) {
            switch rawValue {
                case 0: self = .pending
                case 1: self = .mounted
                default: self = .unrecognized(rawValue)
            }
        }

        public var rawValue: Int32 {
            switch self {
                case .pending: 0
                case .mounted: 1
                case .unrecognized(let value): value
            }
        }

        public var description: String {
            switch self {
                case .pending: "pending"
                case .mounted: "mounted"
                case .unrecognized(let value): "unrecognized(\(value))"
            }
        }
    }

    public let id: String
    public let kind: MountBackendKind
    public let source: String
    public let mountPoint: String
    public var mountedFrom: String
    public var state: State

    public init(
        id: String,
        kind: MountBackendKind,
        source: String,
        mountPoint: String,
        mountedFrom: String,
        state: State
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.mountPoint = mountPoint
        self.mountedFrom = mountedFrom
        self.state = state
    }

    /// Whether this version understands the record well enough to act on it.
    public var isRecognized: Bool {
        if case .unrecognized = kind { return false }
        if case .unrecognized = state { return false }
        return true
    }
}
