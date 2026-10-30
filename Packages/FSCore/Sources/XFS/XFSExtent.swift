import FSCore

/// A mapping of a file's blocks: `count` blocks from `logical` at volume block `physical`; unwritten extents read as zero.
struct XFSExtent: Sendable, Equatable {
    let logical: UInt64
    let physical: UInt64
    let count: UInt64
    let unwritten: Bool

    var end: UInt64 { logical + count }

    /// One packed 128-bit record (`xfs_bmbt_rec`): unwritten flag, 54-bit start offset, 52-bit start block (a file system
    /// block number), 21-bit count.
    struct Record: Equatable {
        let logical: UInt64
        let start: UInt64
        let count: UInt64
        let unwritten: Bool
    }

    static func fields(_ bytes: DiskBytes, _ at: Int) throws(DiskError) -> Record {
        let (high, low) = (try bytes.be64(at), try bytes.be64(at + 8))
        return Record(
            logical: high >> 9 & ((1 << 54) - 1), start: (high & 0x1FF) << 43 | low >> 21, count: low & 0x1F_FFFF,
            unwritten: high >> 63 != 0)
    }

    static func decode(_ bytes: DiskBytes, _ at: Int, _ superblock: XFSSuperblock) throws(DiskError) -> XFSExtent {
        let record = try fields(bytes, at)
        return XFSExtent(
            logical: record.logical, physical: try superblock.diskBlock(record.start), count: record.count,
            unwritten: record.unwritten)
    }
}
