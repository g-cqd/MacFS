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
        0x0010,  // meta_bg (descriptors placed per metagroup; DescriptorLayout)
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
        (0x0001, "compression"), (0x0008, "an external journal device"), (0x1000, "dirdata")
    ]

    let inodeCount: UInt32
    let blockCount: UInt64
    let freeBlocks: UInt64
    let freeInodes: UInt32
    let firstDataBlock: UInt64
    let blockSize: Int
    /// The allocation unit: a block, or with bigalloc a cluster of `2^s_log_cluster_size` KiB.
    let clusterSize: Int
    let blocksPerGroup: UInt32
    let inodesPerGroup: UInt32
    let inodeSize: Int
    let incompat: UInt32
    /// Compatible features: `dir_index` (0x20) makes indexed directories' indexes count.
    let compat: UInt32
    let hasMetadataChecksums: Bool
    /// The metadata checksums, when the volume has them (`metadata_csum`).
    let checksums: ExtChecksums?
    let descriptorSize: Int
    /// `s_first_meta_bg`: under meta_bg, the first metagroup whose descriptors are in its own groups; those before it keep the
    /// table after the superblock (what `resize2fs` leaves when it grows a volume past its table).
    let firstMetaBG: UInt32
    let descriptors: DescriptorLayout
    /// `s_flags`: 1 when directory hashes treat bytes as signed, 2 when unsigned.
    let flags: UInt32
    /// `s_hash_seed`, the directory hashes' seed.
    let hashSeed: [UInt32]
    let uuid: [UInt8]
    let label: String

    // @dl:accept -- each format's header parsed field by field; the shape is the format's, not shared logic
    static func looksLikeOne(_ bytes: [UInt8]) -> Bool {
        (try? DiskBytes(bytes).u16(0x38)) == magic
    }

    init(_ raw: [UInt8]) throws(DiskError) {
        let bytes = DiskBytes(raw)
        guard try bytes.u16(0x38) == Self.magic else { throw .corrupt("no ext superblock") }
        let roCompat = try bytes.u32(0x64)
        hasMetadataChecksums = roCompat & 0x0400 != 0
        hasGroupDescriptorChecksums = roCompat & 0x0410 != 0
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
        let logCluster = try bytes.u32(0x1C)
        guard roCompat & 0x0200 == 0 || (logCluster >= logBlock && logCluster <= 29) else {
            throw .corrupt("cluster size 2^\(10 + logCluster)")
        }
        clusterSize = roCompat & 0x0200 != 0 ? 1024 << Int(logCluster) : blockSize
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
        firstMetaBG = try bytes.u32(0x104)
        flags = try bytes.u32(0x160)
        compat = try bytes.u32(0x5C)
        hashSeed = try (0 ..< 4).map { (index) throws(DiskError) -> UInt32 in try bytes.u32(0xEC + 4 * index) }
        let sparseSuper2 = compat & 0x0200 != 0
        descriptors = DescriptorLayout(
            blockSize: blockSize,
            descriptorsPerBlock: blockSize / descriptorSize,
            blocksPerGroup: blocksPerGroup,
            firstDataBlock: firstDataBlock,
            metaBG: incompat & 0x0010 != 0,
            firstMetaBG: firstMetaBG,
            sparseSuper: roCompat & 0x0001 != 0,
            sparseSuper2: sparseSuper2 ? (try bytes.u32(0x24C), try bytes.u32(0x250)) : nil
        )
        uuid = try bytes.bytes(0x68, 16)
        label = String(decoding: try bytes.bytes(0x78, 16).prefix { $0 != 0 }, as: UTF8.self)
        // s_checksum_seed when csum_seed is set (the UUID may then change), else crc32c(~0, uuid).
        checksums =
            hasMetadataChecksums
            ? ExtChecksums(seed: incompat & 0x2000 != 0 ? try bytes.u32(0x270) : CRC32C.update(~0, uuid)) : nil
    }

    var is64Bit: Bool { incompat & 0x0080 != 0 }
    /// `gdt_csum` or `metadata_csum`: group descriptors carry a checksum.
    let hasGroupDescriptorChecksums: Bool
    var groupCount: UInt64 { (blockCount - firstDataBlock + UInt64(blocksPerGroup) - 1) / UInt64(blocksPerGroup) }

    /// Where the group descriptors live: Linux's `ext4_bg_has_super` and `descriptor_loc` (fs/ext4/super.c, balloc.c).
    struct DescriptorLayout: Sendable {
        var blockSize: Int
        var descriptorsPerBlock: Int
        var blocksPerGroup: UInt32
        var firstDataBlock: UInt64
        var metaBG: Bool
        var firstMetaBG: UInt32
        var sparseSuper: Bool
        var sparseSuper2: (UInt32, UInt32)?

        /// Whether a group starts with a superblock backup: every group without sparse_super; with it, groups 0, 1 and the
        /// powers of 3, 5 and 7; with sparse_super2, group 0 and the two groups the superblock names.
        func hasSuperblock(_ group: UInt64) -> Bool {
            if group == 0 { return true }
            if let (first, second) = sparseSuper2 { return group == UInt64(first) || group == UInt64(second) }
            guard sparseSuper, group > 1 else { return true }
            guard group & 1 == 1 else { return false }
            return [UInt64(3), 5, 7]
                .contains { base in
                    var power: UInt64 = base
                    while power < group { power *= base }
                    return power == group
                }
        }

        /// The block holding descriptor block `index`. Without meta_bg, and for metagroups before `firstMetaBG`, the
        /// table follows the superblock's block (block 1 with 1 KiB blocks, else 0). Under meta_bg, metagroup `index`
        /// keeps its descriptors in the first block of its first group, after that group's superblock backup if any.
        func descriptorBlock(_ index: UInt64) -> UInt64 {
            let superblockBlock = UInt64(1024 / blockSize)
            guard metaBG, index >= UInt64(firstMetaBG) else { return superblockBlock + index + 1 }
            let group = index * UInt64(descriptorsPerBlock)
            var skip: UInt64 = hasSuperblock(group) ? 1 : 0
            // 1 KiB blocks with data from block 0 (bigalloc): group 0's first block is the boot block, then the superblock.
            if blockSize == 1024, index == 0, firstDataBlock == 0 { skip += 1 }
            return group * UInt64(blocksPerGroup) + firstDataBlock + skip
        }
    }
}
