/// Every node under a directory, depth first, without recursion.
///
/// A hostile image can make a directory contain itself, so the walk keeps the identifiers it has
/// entered and stops at a node budget instead of trusting the tree to be finite.
public enum TreeWalk {
    public struct Visit: Sendable {
        /// Slash-separated path from the start, without a leading slash.
        public let path: String
        public let entry: DirectoryEntry
    }

    public static func visit(
        _ fileSystem: any ReadOnlyFileSystem, from start: UInt64? = nil, budget: Int = 1_000_000, pageSize: Int = 64,
        _ body: (Visit) throws(DiskError) -> Void
    ) throws(DiskError) {
        var pending: [(id: UInt64, path: String)] = [(start ?? fileSystem.rootID, "")]
        var entered: Set<UInt64> = []
        var visited = 0
        while let (directory, prefix) = pending.popLast() {
            guard entered.insert(directory).inserted else {
                throw .corrupt("directory \(directory) is reachable twice")
            }
            var cookie: UInt64 = 0
            var children: [(UInt64, String)] = []
            while true {
                let page = try fileSystem.entries(of: directory, from: cookie, limit: pageSize)
                for entry in page {
                    visited += 1
                    guard visited <= budget else { throw .corrupt("more than \(budget) nodes") }
                    let path = prefix.isEmpty ? entry.displayName : prefix + "/" + entry.displayName
                    try body(Visit(path: path, entry: entry))
                    if entry.kind == .directory { children.append((entry.id, path)) }
                }
                guard let last = page.last, page.count == pageSize else { break }
                guard last.nextCookie > cookie else {
                    throw .corrupt("directory \(directory): cookie does not advance")
                }
                cookie = last.nextCookie
            }
            pending.append(contentsOf: children.reversed())
        }
    }
}
