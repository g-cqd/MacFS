import Darwin

/// The mount table from `getmntinfo` (no wait: the kernel's cached list, so a hung network mount cannot block it).
public struct SystemMountTable: MountTable {
    public init() {}

    public func entries() -> [MountTableEntry] {
        var list: UnsafeMutablePointer<statfs>?
        let count = unsafe getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list = unsafe list else { return [] }
        return (0 ..< Int(count))
            .map { index in
                var entry = unsafe list[index]
                return MountTableEntry(
                    mountPoint: Self.string(&entry.f_mntonname),
                    mountedFrom: Self.string(&entry.f_mntfromname),
                    type: Self.string(&entry.f_fstypename)
                )
            }
    }

    /// The real path of the longest existing prefix of `path`, then the rest as given: a mount point need not exist yet.
    public func canonical(_ path: String) -> String {
        var existing = path
        var rest: [Substring] = []
        while !existing.isEmpty, existing != "/" {
            if let real = unsafe realpath(existing, nil) {
                defer { unsafe free(real) }
                return (unsafe [String(cString: real)] + rest.reversed().map(String.init)).joined(separator: "/")
            }
            guard let slash = existing.lastIndex(of: "/") else { break }
            rest.append(existing[existing.index(after: slash)...])
            existing = String(existing[..<slash])
        }
        return path
    }

    private static func string<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { raw in
            unsafe String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
