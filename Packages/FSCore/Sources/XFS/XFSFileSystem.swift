import AemiKernel
public import FSCore

/// A read-only XFS volume (roadmap 0031). Node identifiers are inode numbers; the root is the superblock's. The log is not
/// replayed: a volume that needs recovery reads as of its last checkpoint, as with ext.
public final class XFSFileSystem: ReadOnlyFileSystem {
    public let volume: VolumeDescription
    public let rootID: UInt64

    let source: any BlockSource
    let superblock: XFSSuperblock
    private let blocks: CachedBlocks
    private let extentMaps = BoundedCache<UInt64, [XFSExtent]>(capacity: 512)
    let listings = BoundedCache<UInt64, Listing>(capacity: 256)
    /// Directory blocks a hashed lookup has read, checked (magic, checksum, owner), by directory and logical offset: about
    /// 8 MiB of them.
    let directoryBlocks: BoundedCache<DirectoryBlock, DiskBytes>

    struct DirectoryBlock: Hashable, Sendable {
        let directory: UInt64
        let offset: UInt64
    }

    struct Listing: Sendable {
        let parent: UInt64
        let entries: [XFSDirectory.Entry]
    }

    /// The superblock's magic in the first sector; the full check is opening it.
    public static func probe(_ source: any BlockSource) -> Bool {
        guard let first = try? source.read(at: 0, count: 512) else { return false }
        return XFSSuperblock.looksLikeOne(first)
    }

    public init(source: any BlockSource) throws(DiskError) {
        self.source = source
        let first = try source.read(at: 0, count: 512)
        let sectorSize = Int((try? DiskBytes(first).be16(0x66)) ?? 512)
        superblock = try XFSSuperblock(
            sectorSize > 512 && sectorSize <= 32768 ? try source.read(at: 0, count: sectorSize) : first
        )
        guard superblock.dataBlocks <= source.byteCount / UInt64(superblock.blockSize) + 1 else {
            throw .corrupt("\(superblock.dataBlocks) blocks on a \(source.byteCount)-byte device")
        }
        blocks = CachedBlocks(source, blockSize: superblock.blockSize, blockCount: superblock.dataBlocks)
        directoryBlocks = BoundedCache(capacity: max(16, (8 << 20) / superblock.dirBlockSize))
        rootID = superblock.rootInode
        volume = VolumeDescription(
            format: "xfs",
            label: superblock.label,
            uuid: superblock.uuid,
            caseRule: .sensitive,
            maximumNameLength: 255
        )
        guard try inode(rootID).kind == .directory else { throw .corrupt("the root inode is not a directory") }
    }

    func block(_ number: UInt64) throws(DiskError) -> DiskBytes { try blocks.block(number) }

    /// An inode by number: its group, its block in the group and its slot in the block.
    func inode(_ number: UInt64) throws(DiskError) -> XFSInode {
        let slotBits = UInt64(superblock.inodesPerBlockLog)
        let group = number >> (UInt64(superblock.agBlockLog) + slotBits)
        let inGroup = number >> slotBits & ((1 << UInt64(superblock.agBlockLog)) - 1)
        let slot = Int(number & ((1 << slotBits) - 1))
        guard number > 0, group < superblock.agCount, inGroup < superblock.agBlocks else { throw .notFound }
        let bytes = try block(group * UInt64(superblock.agBlocks) + inGroup)
        let raw = try bytes.slice(slot * superblock.inodeSize, superblock.inodeSize)
        guard try raw.be16(0) == XFSInode.magic, try raw.be16(2) != 0 else { throw .notFound }
        return try XFSInode(raw, number: number, superblock: superblock)
    }

    func extents(_ inode: XFSInode) throws(DiskError) -> [XFSExtent] {
        try extentMaps.value(for: inode.number) { () throws(DiskError) -> [XFSExtent] in
            try XFSExtentMap.extents(inode, superblock) { (number) throws(DiskError) in try block(number) }
        }
    }

    /// `count` bytes of a fork's mapped content from `offset`, past its size if asked (directory blocks); holes and
    /// unwritten extents read as zero.
    func mapped(_ inode: XFSInode, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard !inode.isRealtime else { throw .unsupported("XFS realtime files") }
        let extents = try extents(inode)
        let blockSize = UInt64(superblock.blockSize)
        let end = offset + UInt64(count)
        return try ReadAssembly.assemble(count: count) { (pieces) throws(DiskError) in
            let first = offset / blockSize
            var index = extents.firstIndex { $0.end > first } ?? extents.count
            while index < extents.count, extents[index].logical * blockSize < end {
                let extent = extents[index]
                index += 1
                let low = max(offset, extent.logical * blockSize)
                let high = min(end, extent.end * blockSize)
                guard low < high, !extent.unwritten else { continue }
                guard
                    let physical = (extent.physical + (low / blockSize - extent.logical))
                        .checkedMultiplied(by: blockSize)
                else { throw .corrupt("block \(extent.physical)") }
                try pieces.read(source, at: physical + low % blockSize, to: Int(low - offset), count: Int(high - low))
            }
        }
    }

    public func statistics() throws(DiskError) -> VolumeStatistics {
        VolumeStatistics(
            blockSize: superblock.blockSize,
            totalBlocks: superblock.dataBlocks,
            freeBlocks: superblock.freeBlocks,
            files: superblock.inodeCount &- superblock.freeInodes
        )
    }
}
