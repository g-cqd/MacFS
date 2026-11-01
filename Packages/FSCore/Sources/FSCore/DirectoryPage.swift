/// One page of a directory's listing for `entries(of:from:limit:)`: the cookie is the position in the listing, and each
/// entry's next cookie the position after it.
public enum DirectoryPage {
    public static func page(
        count: Int,
        from cookie: UInt64,
        limit: Int,
        _ entry: (_ position: Int) throws(DiskError) -> DirectoryEntry
    ) throws(DiskError) -> [DirectoryEntry] {
        guard cookie < UInt64(count) else { return [] }
        let start = Int(cookie)
        var page: [DirectoryEntry] = []
        for position in start ..< min(count, start + max(0, limit)) { page.append(try entry(position)) }
        return page
    }
}
