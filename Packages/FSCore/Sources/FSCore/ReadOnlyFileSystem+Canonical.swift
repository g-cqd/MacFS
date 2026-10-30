extension ReadOnlyFileSystem {
    /// `lookup`, as macOS callers need it (roadmap 0022): Cocoa and Finder pass decomposed (NFD) names, Linux and Windows
    /// store precomposed (NFC) ones. The exact name wins; when it misses and the name is UTF-8 beyond ASCII, the first entry
    /// canonically equivalent to it (Swift's `String ==`) is the name, as APFS treats names. Only such misses pay a scan of the
    /// directory, which the readers cache.
    public func lookupCanonical(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        do {
            return try lookup(name, in: directory)
        } catch {
            guard case .notFound = error, name.contains(where: { $0 >= 0x80 }),
                let wanted = String(validating: name, as: UTF8.self)
            else { throw error }
            var cookie: UInt64 = 0
            var scanned = 0
            while scanned < 1 << 22 {
                let page = try entries(of: directory, from: cookie, limit: 256)
                if let match = page.first(where: { String(validating: $0.name, as: UTF8.self) == wanted }) {
                    return match
                }
                guard let last = page.last, page.count == 256, last.nextCookie > cookie else { break }
                cookie = last.nextCookie
                scanned += page.count
            }
            throw error
        }
    }
}
