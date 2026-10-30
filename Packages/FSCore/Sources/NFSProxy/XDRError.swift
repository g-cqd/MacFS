/// Why bytes from a client could not be decoded. Clients are untrusted like disks are.
public enum XDRError: Error, Equatable, Sendable {
    case truncated
    case tooLong
}
