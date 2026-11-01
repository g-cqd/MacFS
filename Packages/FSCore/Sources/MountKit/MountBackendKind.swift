/// The technology a mount goes through (ADR-0013). Open: a kind written by a newer version is kept as `unrecognized` and never
/// acted on (ADR-0015). The numbers are stable: they are what the registry stores.
public enum MountBackendKind: Hashable, Sendable, CustomStringConvertible {
    case fsKit
    case nfs
    case webDAV
    case fileProvider
    case unrecognized(Int32)

    public static let allKnown: [Self] = [.fsKit, .nfs, .webDAV, .fileProvider]

    public init(rawValue: Int32) {
        self = Self.allKnown.first { $0.rawValue == rawValue } ?? .unrecognized(rawValue)
    }

    public var rawValue: Int32 {
        switch self {
            case .fsKit: 0
            case .nfs: 1
            case .webDAV: 2
            case .fileProvider: 3
            case .unrecognized(let value): value
        }
    }

    public var description: String {
        switch self {
            case .fsKit: "fsKit"
            case .nfs: "nfs"
            case .webDAV: "webDAV"
            case .fileProvider: "fileProvider"
            case .unrecognized(let value): "unrecognized(\(value))"
        }
    }
}
