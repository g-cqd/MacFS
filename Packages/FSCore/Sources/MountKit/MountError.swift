/// Why a mount operation did not happen.
public enum MountError: Error, Hashable, Sendable {
    case unavailable(MountBackendKind, String)
    case noBackend(MountBackendKind)
    case mountPointInUse(String)
    case notFound(String)
    /// A record of a kind or state this version does not understand: kept, never acted on (ADR-0015).
    case unrecognized(String)
    case backend(String)
    case registry(String)
}
