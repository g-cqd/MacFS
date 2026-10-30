import AemiKernel
import FSCore

/// The XFS superblock (`struct xfs_dsb`), big-endian, in the first sector of the volume.
struct XFSSuperblock: Sendable {
    static let magic: UInt32 = 0x5846_5342  // "XFSB"
    // Incompatible features read here: ftype, sparse inodes, meta_uuid, bigtime, nrext64, exchange-range, parent pointers,
    // metadir. needsrepair (0x10) is refused, as the kernel refuses to mount it.
    private static let understoodIncompat: UInt32 = 0x01 | 0x02 | 0x04 | 0x08 | 0x20 | 0x40 | 0x80 | 0x100

    let blockSize: Int
    let blockLog: Int
    let dataBlocks: UInt64
    let uuid: [UInt8]
    let rootInode: UInt64
    let agBlocks: UInt32
    let agCount: UInt32
    let sectorSize: Int
    let inodeSize: Int
    let inodesPerBlockLog: Int
    let agBlockLog: Int
    let dirBlockLog: Int
    let version: Int
    let incompat: UInt32
    let label: String
    let inodeCount: UInt64
    let freeInodes: UInt64
    let freeBlocks: UInt64

    var hasCRC: Bool { version == 5 }
    /// Directory entries carry the file type (the ftype feature, set on every volume mkfs.xfs makes).
    var hasFileType: Bool { incompat & 0x01 != 0 }
    var dirBlockSize: Int { blockSize << dirBlockLog }

    // @dl:accept -- each format's header parsed field by field; the shape is the format's, not shared logic
    static func looksLikeOne(_ bytes: [UInt8]) -> Bool { (try? DiskBytes(bytes).be32(0)) == magic }

    init(_ raw: [UInt8]) throws(DiskError) {
        let bytes = DiskBytes(raw)
        guard try bytes.be32(0) == Self.magic else { throw .corrupt("no XFS superblock") }
        version = Int(try bytes.be16(0x64) & 0x000F)
        // v4 is deprecated, and the Linux kernel MacFS is checked against is built without it: with no reference to hold a
        // reader to, it is refused (docs/conformance/xfs.md).
        if version == 4 { throw .unsupported("XFS v4 volumes") }
        guard version == 5 else { throw .unsupported("XFS version \(version)") }
        // ASCII case-insensitive volumes (versionnum's BORGBIT, 0x4000) hash and compare names folded: deprecated, and refused
        // by the same kernel, so refused here too (docs/conformance/xfs.md).
        if try bytes.be16(0x64) & 0x4000 != 0 { throw .unsupported("XFS ASCII case-insensitive volumes") }
        sectorSize = Int(try bytes.be16(0x66))
        guard [512, 1024, 2048, 4096, 8192, 16384, 32768].contains(sectorSize), sectorSize <= raw.count else {
            throw .corrupt("sector size \(sectorSize)")
        }
        let stored = try bytes.u32(0xE0)
        let computed = try XFSChecksum.compute(try bytes.slice(0, sectorSize), at: 0xE0)
        guard computed == stored else { throw .checksum("superblock") }
        blockSize = Int(try bytes.be32(0x04))
        blockLog = Int(try bytes.u8(0x78))
        guard blockLog >= 9, blockLog <= 16, blockSize == 1 << blockLog else {
            throw .corrupt("block size \(blockSize)")
        }
        dataBlocks = try bytes.be64(0x08)
        // @dl:accept -- each format's header parsed field by field; the shape is the format's, not shared logic
        uuid = try bytes.bytes(0x20, 16)
        rootInode = try bytes.be64(0x38)
        agBlocks = try bytes.be32(0x54)
        agCount = try bytes.be32(0x58)
        inodeSize = Int(try bytes.be16(0x68))
        inodesPerBlockLog = Int(try bytes.u8(0x7B))
        agBlockLog = Int(try bytes.u8(0x7C))
        dirBlockLog = Int(try bytes.u8(0xC0))
        guard agBlocks > 0, agCount > 0, agBlockLog <= 31, 1 << agBlockLog >= agBlocks,
            [256, 512, 1024, 2048].contains(inodeSize), blockSize >> inodesPerBlockLog == inodeSize,
            dirBlockLog <= 6, blockSize << dirBlockLog <= 65536
        else { throw .corrupt("\(agCount) groups of \(agBlocks) blocks, \(inodeSize)-byte inodes") }
        incompat = try bytes.be32(0xD8)
        if incompat & 0x10 != 0 { throw .unsupported("an XFS volume that needs repair") }
        let unknown = incompat & ~Self.understoodIncompat
        guard unknown == 0 else { throw .unsupported("XFS incompatible features 0x\(String(unknown, radix: 16))") }
        label = String(decoding: try bytes.bytes(0x6C, 12).prefix { $0 != 0 }, as: UTF8.self)
        inodeCount = try bytes.be64(0x80)
        freeInodes = try bytes.be64(0x88)
        freeBlocks = try bytes.be64(0x90)
    }

    /// The volume block of a file system block number (`XFS_FSB_TO_DADDR` in blocks): AG number high, block in AG low.
    func diskBlock(_ fsb: UInt64) throws(DiskError) -> UInt64 {
        let ag = fsb >> agBlockLog
        let inAG = fsb & ((1 << agBlockLog) - 1)
        guard ag < agCount, inAG < agBlocks else { throw .corrupt("block \(fsb) outside the volume's groups") }
        return ag * UInt64(agBlocks) + inAG
    }
}
