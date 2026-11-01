public import FSCore

/// A reader as a mount technology sees it: identifiers where 1 is the root's parent and 2 the root
/// (FSKit's `FSItem.Identifier`, and NFS file ids by convention), and listings that carry `.` and `..`.
///
/// Mount cookies: 0 starts a listing, 2 resumes at `..`, and from 3 on a cookie is the reader's cookie
/// plus 3. Cookie 1 is never handed out, so it is refused.
public struct MountedTree: Sendable {
    public struct PageEntry: Sendable, Equatable {
        public var name: [UInt8]
        public var kind: NodeKind
        public var mountID: UInt64
        public var nextCookie: UInt64

        public var displayName: String { String(decoding: name, as: UTF8.self) }
    }

    public static let parentOfRoot: UInt64 = 1
    public static let root: UInt64 = 2
    private static let firstEntryCookie: UInt64 = 3

    public let fileSystem: any ReadOnlyFileSystem

    public init(_ fileSystem: any ReadOnlyFileSystem) throws(DiskError) {
        self.fileSystem = fileSystem
    }

    public func mountID(for readerID: UInt64) -> UInt64 {
        readerID == fileSystem.rootID ? Self.root : readerID
    }

    /// Like ``mountID(for:)``, refusing a reader identifier that would alias a reserved one.
    public func checkedMountID(for readerID: UInt64) throws(DiskError) -> UInt64 {
        let id = mountID(for: readerID)
        guard id > Self.root || readerID == fileSystem.rootID else {
            throw .corrupt("node identifier \(readerID) collides with a reserved mount identifier")
        }
        return id
    }

    public func readerID(for mountID: UInt64) -> UInt64 {
        mountID == Self.root ? fileSystem.rootID : mountID
    }

    public func parentMountID(of attributes: NodeAttributes) -> UInt64 {
        attributes.id == fileSystem.rootID ? Self.parentOfRoot : mountID(for: attributes.parent)
    }

    public func page(of directory: UInt64, from cookie: UInt64, includeDots: Bool, limit: Int) throws(DiskError)
        -> [PageEntry]
    {
        guard cookie != 1, limit > 0 else { throw .corrupt("directory cookie \(cookie)") }
        let reader = readerID(for: directory)
        var page: [PageEntry] = []
        if includeDots, cookie < Self.firstEntryCookie {
            let attributes = try fileSystem.attributes(of: reader)
            guard attributes.kind == .directory else { throw .notDirectory }
            if cookie == 0 { page.append(PageEntry(name: [0x2E], kind: .directory, mountID: directory, nextCookie: 2)) }
            let parent = directory == Self.root ? Self.root : parentMountID(of: attributes)
            page.append(
                PageEntry(name: [0x2E, 0x2E], kind: .directory, mountID: parent, nextCookie: Self.firstEntryCookie)
            )
            if page.count >= limit { return Array(page.prefix(limit)) }
        }
        let readerCookie = cookie < Self.firstEntryCookie ? 0 : cookie - Self.firstEntryCookie
        for entry in try fileSystem.entries(of: reader, from: readerCookie, limit: limit - page.count) {
            page.append(
                PageEntry(
                    name: entry.name,
                    kind: entry.kind,
                    mountID: try checkedMountID(for: entry.id),
                    nextCookie: entry.nextCookie + Self.firstEntryCookie
                )
            )
        }
        return page
    }
}
