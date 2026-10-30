import AemiKernel
import FSCore

/// The ext2/3/4 superblock (`struct ext4_super_block`), at byte 1024 of the volume.
struct ExtSuperblock: Sendable {
    static let offset: UInt64 = 1024
    static let size = 1024
    static let magic: UInt16 = 0xEF53

    // Incompatible features: refused unless listed as understood.
    private static let understoodIncompat: UInt32 = [
        0x0002,  // filetype
        0x0004,  // needs recovery (the journal is not replayed; see ExtFileSystem)
        0x0040,  // extents
        0x0080,  // 64bit
        0x0100,  // mmp
        0x0200,  // flex_bg
        0x0400,  // ea_inode
        0x2000,  // csum_seed
        0x4000,  // largedir
        0x8000,  // inline_data
        0x10000,  // encrypt (encrypted inodes are refused one by one)
        0x20000  // casefold (names are matched exactly)
    ]
    .reduce(0, |)
    private static let namedIncompat: [(UInt32, String)] = [
        (0x0001, "compression"), (0x0008, "an external journal device"), (0x0010, "meta_bg"), (0x1000, "dirdata")
    ]

    let inodeCount: UInt32
    let blockCount: UInt64
    let freeBlocks: UInt64
    let freeInodes: UInt32
    let firstDataBlock: UInt64
    let blockSize: Int
    let blocksPerGroup: UInt32
    let inodesPerGroup: UInt32
    let inodeSize: Int
    let incompat: UInt32
    let hasMetadataChecksums: Bool
    let descriptorSize: Int
    let uuid: [UInt8]
    let label: String

    static func looksLikeOne(_ bytes: [UInt8]) -> Bool {
        (try? DiskBytes(bytes).u16(0x38)) == magic
    }

    init(_ raw: [UInt8]) throws(DiskError) {
        let bytes = DiskBytes(raw)
        guard try bytes.u16(0x38) == Self.magic else { throw .corrupt("no ext superblock") }
        let roCompat = try bytes.u32(0x64)
        hasMetadataChecksums = roCompat & 0x0400 != 0
        if hasMetadataChecksums {
            // ext4_superblock_csum: crc32c seeded with ~0, not inverted, over the bytes before the field.
            guard CRC32C.update(~0, raw[0 ..< 0x3FC]) == (try bytes.u32(0x3FC)) else { throw .checksum("superblock") }
        }
        incompat = try bytes.u32(0x60)
        for (flag, name) in Self.namedIncompat where incompat & flag != 0 { throw .unsupported(name) }
        let unknown = incompat & ~Self.understoodIncompat
        guard unknown == 0 else { throw .unsupported("incompatible features 0x\(String(unknown, radix: 16))") }
        let wide = incompat & 0x0080 != 0
        inodeCount = try bytes.u32(0x00)
        blockCount = UInt64(try bytes.u32(0x04)) | (wide ? UInt64(try bytes.u32(0x150)) << 32 : 0)
        freeBlocks = UInt64(try bytes.u32(0x0C)) | (wide ? UInt64(try bytes.u32(0x158)) << 32 : 0)
        freeInodes = try bytes.u32(0x10)
        firstDataBlock = UInt64(try bytes.u32(0x14))
        let logBlock = try bytes.u32(0x18)
        guard logBlock <= 6 else { throw .corrupt("block size 2^\(10 + logBlock)") }
        blockSize = 1024 << Int(logBlock)
        blocksPerGroup = try bytes.u32(0x20)
        inodesPerGroup = try bytes.u32(0x28)
        let revision = try bytes.u32(0x4C)
        inodeSize = revision == 0 ? 128 : Int(try bytes.u16(0x58))
        guard blocksPerGroup > 0, inodesPerGroup > 0, inodeSize >= 128, inodeSize <= blockSize,
            inodeSize.nonzeroBitCount == 1
        else {
            throw .corrupt("\(blocksPerGroup) blocks and \(inodesPerGroup) inodes of \(inodeSize) bytes per group")
        }
        descriptorSize = wide ? Int(try bytes.u16(0xFE)) : 32
        guard descriptorSize >= 32, descriptorSize <= 1024, descriptorSize.nonzeroBitCount == 1 else {
            throw .corrupt("group descriptor of \(descriptorSize) bytes")
        }
        uuid = try bytes.bytes(0x68, 16)
        label = String(decoding: try bytes.bytes(0x78, 16).prefix { $0 != 0 }, as: UTF8.self)
    }

    var is64Bit: Bool { incompat & 0x0080 != 0 }
    var groupCount: UInt64 { (blockCount - firstDataBlock + UInt64(blocksPerGroup) - 1) / UInt64(blocksPerGroup) }
}
