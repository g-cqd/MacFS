import FSCore

/// An XFS inode (`struct xfs_dinode`), big-endian: the core, then the data fork, then the attribute fork.
struct XFSInode: Sendable {
    // @dl:accept -- each format's header parsed field by field; the shape is the format's, not shared logic
    static let magic: UInt16 = 0x494E  // "IN"
    static let local: UInt8 = 1
    static let extents: UInt8 = 2
    static let btree: UInt8 = 3

    let number: UInt64
    let raw: DiskBytes
    let mode: UInt16
    let version: UInt8
    let format: UInt8
    let uid: UInt32
    let gid: UInt32
    let linkCount: UInt32
    let size: UInt64
    let blocks: UInt64
    let extentCount: UInt64
    let flags: UInt16
    let flags2: UInt64
    let dataFork: DiskBytes

    var kind: NodeKind { NodeKind(posixMode: UInt32(mode)) }
    /// XFS_DIFLAG_REALTIME: the data is on the realtime device, which this reader does not open.
    var isRealtime: Bool { flags & 0x0001 != 0 }

    init(_ raw: DiskBytes, number: UInt64, superblock: XFSSuperblock) throws(DiskError) {
        guard try raw.be16(0) == Self.magic else { throw .corrupt("inode \(number): no inode magic") }
        version = try raw.u8(4)
        // @dl:accept -- XFS checks each structure's magic, checksum and owner; the structures differ
        guard version == 3 else { throw .corrupt("inode \(number): version \(version) on a v5 volume") }
        try XFSChecksum.verify(raw, at: 100, "inode \(number)")
        guard try raw.be64(152) == number else { throw .corrupt("inode \(number): records itself as another") }
        self.number = number
        // @dl:accept -- each format's header parsed field by field; the shape is the format's, not shared logic
        self.raw = raw
        mode = try raw.be16(2)
        format = try raw.u8(5)
        uid = try raw.be32(8)
        gid = try raw.be32(12)
        linkCount = try raw.be32(16)
        size = try raw.be64(56)
        blocks = try raw.be64(64)
        flags = try raw.be16(90)
        flags2 = try raw.be64(120)
        // XFS_DIFLAG2_NREXT64: the data fork's extent count is 64 bits, where v3 inodes otherwise pad.
        extentCount = flags2 & 0x10 != 0 ? try raw.be64(24) : UInt64(try raw.be32(76))
        let core = 176
        let forkOffset = Int(try raw.u8(82))
        let forkSize = forkOffset != 0 ? forkOffset * 8 : raw.count - core
        guard forkSize > 0, core + forkSize <= raw.count else {
            throw .corrupt("inode \(number): fork of \(forkSize) bytes")
        }
        dataFork = try raw.slice(core, forkSize)
    }

    /// A timestamp at `offset`: seconds and nanoseconds, or with bigtime (XFS_DIFLAG2_BIGTIME) nanoseconds since 1901-12-13.
    func time(_ offset: Int) throws(DiskError) -> Timestamp {
        if flags2 & 0x08 != 0 {
            let value = try raw.be64(offset)
            return Timestamp(
                seconds: Int64(value / 1_000_000_000) - (1 << 31),
                nanoseconds: Int32(value % 1_000_000_000)
            )
        }
        return Timestamp(
            seconds: Int64(Int32(bitPattern: try raw.be32(offset))),
            nanoseconds: Int32(bitPattern: try raw.be32(offset + 4))
        )
    }
}
