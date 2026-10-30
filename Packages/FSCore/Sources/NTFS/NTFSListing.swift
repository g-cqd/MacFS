import FSCore

/// The visible names of one directory, in collation order, with a folded-name index for lookup.
struct NTFSListing: Sendable {
    struct Name: Sendable {
        let record: UInt64
        let fileName: NTFSFileName
        let folded: [UInt16]
    }

    let names: [Name]
    private let byFolded: [[UInt16]: Int]

    init(_ names: [Name]) {
        let sorted = names.sorted { $0.folded.lexicographicallyPrecedes($1.folded) }
        self.names = sorted
        var index: [[UInt16]: Int] = [:]
        for (position, name) in sorted.enumerated() where index[name.folded] == nil { index[name.folded] = position }
        self.byFolded = index
    }

    /// The exact name if present (POSIX names may differ only by case), else the case-folded match.
    func find(units: [UInt16], folded: [UInt16]) -> Name? {
        if let exact = names.first(where: { $0.fileName.units == units }) { return exact }
        return byFolded[folded].map { names[$0] }
    }
}
