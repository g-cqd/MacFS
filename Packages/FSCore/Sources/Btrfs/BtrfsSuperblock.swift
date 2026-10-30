import FSCore

/// The fields of the superblock this reader needs (`struct btrfs_super_block`).
struct BtrfsSuperblock: Sendable {
    static let size = 4096
    /// The primary copy and the two mirrors.
    static let offsets: [UInt64] = [0x1_0000, 0x400_0000, 0x40_0000_0000]
    static let magic: [UInt8] = Array("_BHRfS_M".utf8)

    /// Incompatible features whose layout this reader does not know.
    private static let refusedIncompat: [(UInt64, String)] = [
        (1 << 13, "extent tree v2"), (1 << 14, "the RAID stripe tree")
    ]
    private static let metadataUUIDFlag: UInt64 = 1 << 10

    let fsid: [UInt8]
    /// What tree block headers carry: the fsid, or the metadata UUID when that feature is on.
    let metadataFSID: [UInt8]
    let generation: UInt64
    let rootTree: UInt64
    let chunkTree: UInt64
    let totalBytes: UInt64
    let bytesUsed: UInt64
    let rootDirectoryObject: UInt64
    let deviceCount: UInt64
    let sectorSize: Int
    let nodeSize: Int
    let checksum: BtrfsChecksum
    let deviceID: UInt64
    let label: String
    let systemChunkArray: DiskBytes

    /// Whether `bytes` start like a superblock, without validating anything else (for probing).
    static func looksLikeOne(_ bytes: [UInt8]) -> Bool {
        DiskBytes(bytes).matches(magic, at: 0x40)
    }

    init(_ raw: [UInt8], at location: UInt64) throws(DiskError) {
        let bytes = DiskBytes(raw)
        guard bytes.count >= Self.size, bytes.matches(Self.magic, at: 0x40) else {
            throw .corrupt("no Btrfs superblock")
        }
        guard try bytes.u64(0x30) == location else { throw .corrupt("superblock records another location") }
        checksum = try BtrfsChecksum(type: try bytes.u16(0xC4))
        guard checksum.verifies(try bytes.slice(0, Self.size)) else { throw .checksum("superblock at \(location)") }
        let incompat = try bytes.u64(0xBC)
        for (flag, name) in Self.refusedIncompat where incompat & flag != 0 { throw .unsupported(name) }
        fsid = try bytes.bytes(0x20, 16)
        metadataFSID = incompat & Self.metadataUUIDFlag != 0 ? try bytes.bytes(0x23B, 16) : fsid
        generation = try bytes.u64(0x48)
        rootTree = try bytes.u64(0x50)
        chunkTree = try bytes.u64(0x58)
        totalBytes = try bytes.u64(0x70)
        bytesUsed = try bytes.u64(0x78)
        rootDirectoryObject = try bytes.u64(0x80)
        deviceCount = try bytes.u64(0x88)
        sectorSize = Int(try bytes.u32(0x90))
        nodeSize = Int(try bytes.u32(0x94))
        guard [4096, 8192, 16384, 32768, 65536].contains(sectorSize), (sectorSize ... 65536).contains(nodeSize),
            nodeSize.nonzeroBitCount == 1
        else { throw .corrupt("sector size \(sectorSize), node size \(nodeSize)") }
        deviceID = try bytes.u64(0xC9)
        let labelBytes = try bytes.bytes(0x12B, 256)
        label = String(decoding: labelBytes.prefix { $0 != 0 }, as: UTF8.self)
        let arraySize = Int(try bytes.u32(0xA0))
        guard arraySize <= 2048 else { throw .corrupt("system chunk array of \(arraySize) bytes") }
        systemChunkArray = try bytes.slice(0x32B, arraySize)
    }
}
