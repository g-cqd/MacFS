public import FSCore

extension ExtFileSystem {
    /// What the superblock's state says (roadmap 0046): Linux marks a volume clean at unmount, and records the errors it met.
    public func consistencyProblems() throws(DiskError) -> [String] {
        let state = try DiskBytes(try source.read(at: ExtSuperblock.offset, count: ExtSuperblock.size)).u16(0x3A)
        var problems: [String] = []
        if state & Self.validState == 0 { problems.append("the volume was not cleanly unmounted") }
        if state & Self.errorState != 0 { problems.append("the volume records errors found while it was mounted") }
        return problems
    }
}
