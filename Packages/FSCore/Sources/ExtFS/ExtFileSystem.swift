import AemiKernel
public import FSCore

/// A read-only ext2, ext3 or ext4 volume. Node identifiers are inode numbers; the root is inode 2.
/// The journal is not replayed: a volume that needs recovery reads as of its last checkpoint.
public final class ExtFileSystem: ReadOnlyFileSystem {
    public let volume: VolumeDescription
    public let rootID: UInt64 = 2

    let source: any BlockSource
    let superblock: ExtSuperblock
    private let inodeTables: [UInt64]
    private let blocks = BoundedCache<UInt64, DiskBytes>(capacity: 1024)
    let mappings = BoundedCache<UInt64, [ExtRun]>(capacity: 512)
    let listings = BoundedCache<UInt64, [ExtDirectoryBlock.Entry]>(capacity: 256)

    public static func probe(_ source: any BlockSource) -> Bool {
        (try? source.read(at: ExtSuperblock.offset, count: ExtSuperblock.size)).map(ExtSuperblock.looksLikeOne) ?? false
    }

    public init(source: any BlockSource) throws(DiskError) {
        self.source = source
        superblock = try ExtSuperblock(try source.read(at: ExtSuperblock.offset, count: ExtSuperblock.size))
        let groups = superblock.groupCount
        guard groups > 0, groups <= 1 << 32,
            superblock.blockCount <= source.byteCount / UInt64(superblock.blockSize) + 1
        else {
            throw .corrupt("\(groups) groups of \(superblock.blockCount) blocks on a \(source.byteCount)-byte device")
        }
        // The descriptor table starts in the block after the superblock's.
        let tableStart = (superblock.firstDataBlock + 1) * UInt64(superblock.blockSize)
        let raw = DiskBytes(try source.read(at: tableStart, count: Int(groups) * superblock.descriptorSize))
        var tables: [UInt64] = []
        tables.reserveCapacity(Int(groups))
        for group in 0 ..< Int(groups) {
            let at = group * superblock.descriptorSize
            try superblock.checksums?
                .verifyDescriptor(
                    try raw.slice(at, superblock.descriptorSize), group: UInt32(truncatingIfNeeded: group))
            let high = superblock.is64Bit ? UInt64(try raw.u32(at + 0x28)) << 32 : 0
            tables.append(high | UInt64(try raw.u32(at + 8)))
        }
        inodeTables = tables
        volume = VolumeDescription(
            format: "ext4", label: superblock.label, uuid: superblock.uuid, caseRule: .sensitive, maximumNameLength: 255
        )
    }

    func block(_ number: UInt64) throws(DiskError) -> DiskBytes {
        try blocks.value(for: number) { () throws(DiskError) -> DiskBytes in
            guard number < superblock.blockCount,
                let offset = number.checkedMultiplied(by: UInt64(superblock.blockSize))
            else {
                throw .corrupt("block \(number) of \(superblock.blockCount)")
            }
            return DiskBytes(try source.read(at: offset, count: superblock.blockSize))
        }
    }

    func inode(_ number: UInt64) throws(DiskError) -> ExtInode {
        guard number >= 1, number <= UInt64(superblock.inodeCount) else { throw .notFound }
        let index = number - 1
        let group = Int(index / UInt64(superblock.inodesPerGroup))
        let slot = index % UInt64(superblock.inodesPerGroup)
        let byteInTable = slot * UInt64(superblock.inodeSize)
        let blockSize = UInt64(superblock.blockSize)
        let block = try block(inodeTables[group] + byteInTable / blockSize)
        let raw = try block.slice(Int(byteInTable % blockSize), superblock.inodeSize)
        let inode = try ExtInode(raw, number: number, checksums: superblock.checksums)
        guard inode.mode != 0 || number == rootID else { throw .notFound }
        if let checksums = superblock.checksums {
            try checksums.verifyInode(raw, number: number, generation: inode.generation, extraSize: inode.extraSize)
        }
        return inode
    }

    public func statistics() throws(DiskError) -> VolumeStatistics {
        VolumeStatistics(
            blockSize: superblock.blockSize, totalBlocks: superblock.blockCount, freeBlocks: superblock.freeBlocks,
            files: UInt64(superblock.inodeCount - superblock.freeInodes))
    }
}
