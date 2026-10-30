/// One name in a directory listing.
public struct DirectoryEntry: Sendable, Equatable {
    /// The name as UTF-8 bytes, exactly as the file system stores it (Btrfs names are bytes, not text).
    public var name: [UInt8]
    public var id: UInt64
    public var kind: NodeKind
    /// Where a listing resumes to return the entry after this one.
    public var nextCookie: UInt64

    public init(name: [UInt8], id: UInt64, kind: NodeKind, nextCookie: UInt64) {
        self.name = name
        self.id = id
        self.kind = kind
        self.nextCookie = nextCookie
    }

    public var displayName: String { String(decoding: name, as: UTF8.self) }
}
