import AemiKernel
public import FSCore
import Synchronization

/// A read-only ext2, ext3 or ext4 volume. Node identifiers are inode numbers; the root is inode 2.
/// The journal is not replayed: a volume that needs recovery reads as of its last checkpoint.
public final class ExtFileSystem: ReadOnlyFileSystem {
    public let volume: VolumeDescription
    public let rootID: UInt64 = 2

    let source: any BlockSource
    let superblock: ExtSuperblock
    private let inodeTables: [UInt64]
    let blocks: CachedBlocks
    /// The device writes go to, once `beginWriting` set it; nil for a read-only volume (ADR-0018).
    let writingDevice = Mutex<(any WritableBlockSource)?>(nil)
    let clock: @Sendable () -> Timestamp
    /// Set by `close`: no change after the unmount.
    let closed = Mutex(false)
    /// The volume's free blocks as this session's writes left them (nil until one allocates), written at `close`. Its lock
    /// also makes writes one at a time.
    let freeCounts = Mutex<ExtFreeCounts?>(nil)
    let mappings = BoundedCache<UInt64, [ExtRun]>(capacity: 512)
    let listings = BoundedCache<UInt64, [ExtDirectoryBlock.Entry]>(capacity: 256)

    public static func probe(_ source: any BlockSource) -> Bool {
        (try? source.read(at: ExtSuperblock.offset, count: ExtSuperblock.size)).map(ExtSuperblock.looksLikeOne) ?? false
    }

    /// `clock` dates the changes once the volume writes: the system's by default.
    public init(
        source: any BlockSource,
        clock: @escaping @Sendable () -> Timestamp = { .now }
    ) throws(DiskError) {
        self.source = source
        self.clock = clock
        superblock = try ExtSuperblock(try source.read(at: ExtSuperblock.offset, count: ExtSuperblock.size))
        blocks = CachedBlocks(source, blockSize: superblock.blockSize, blockCount: superblock.blockCount)
        let groups = superblock.groupCount
        guard groups > 0, groups <= 1 << 32,
            superblock.blockCount <= source.byteCount / UInt64(superblock.blockSize) + 1
        else {
            throw .corrupt("\(groups) groups of \(superblock.blockCount) blocks on a \(source.byteCount)-byte device")
        }
        // Descriptor blocks where the layout puts them (one table, or one block per metagroup), consecutive ones in one read.
        let blockSize = UInt64(superblock.blockSize)
        let needed = (Int(groups) * superblock.descriptorSize + superblock.blockSize - 1) / superblock.blockSize
        var runs: [(first: UInt64, count: Int)] = []
        for index in 0 ..< UInt64(needed) {
            let block = superblock.descriptors.descriptorBlock(index)
            guard block < superblock.blockCount else { throw .corrupt("descriptor block \(index) at block \(block)") }
            if let last = runs.last, last.first + UInt64(last.count) == block {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((block, 1))
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(needed * superblock.blockSize)
        for run in runs { bytes += try source.read(at: run.first * blockSize, count: run.count * superblock.blockSize) }
        let raw = DiskBytes(bytes)
        var tables: [UInt64] = []
        tables.reserveCapacity(Int(groups))
        for group in 0 ..< Int(groups) {
            let at = group * superblock.descriptorSize
            try superblock.checksums?
                .verifyDescriptor(
                    try raw.slice(at, superblock.descriptorSize),
                    group: UInt32(truncatingIfNeeded: group)
                )
            let high = superblock.is64Bit ? UInt64(try raw.u32(at + 0x28)) << 32 : 0
            tables.append(high | UInt64(try raw.u32(at + 8)))
        }
        inodeTables = tables
        volume = VolumeDescription(
            format: "ext4",
            label: superblock.label,
            uuid: superblock.uuid,
            caseRule: .sensitive,
            maximumNameLength: 255
        )
    }

    func block(_ number: UInt64) throws(DiskError) -> DiskBytes { try blocks.block(number) }

    /// The inode table block holding inode `number`, and the inode's offset in it.
    func inodeLocation(_ number: UInt64) throws(DiskError) -> (block: UInt64, offset: Int) {
        guard number >= 1, number <= UInt64(superblock.inodeCount) else { throw .notFound }
        let index = number - 1
        let group = Int(index / UInt64(superblock.inodesPerGroup))
        let slot = index % UInt64(superblock.inodesPerGroup)
        let byteInTable = slot * UInt64(superblock.inodeSize)
        let blockSize = UInt64(superblock.blockSize)
        return (inodeTables[group] + byteInTable / blockSize, Int(byteInTable % blockSize))
    }

    func inode(_ number: UInt64) throws(DiskError) -> ExtInode {
        let location = try inodeLocation(number)
        let raw = try block(location.block).slice(location.offset, superblock.inodeSize)
        let inode = try ExtInode(raw, number: number, checksums: superblock.checksums)
        guard inode.mode != 0 || number == rootID else { throw .notFound }
        if let checksums = superblock.checksums {
            try checksums.verifyInode(raw, number: number, generation: inode.generation, extraSize: inode.extraSize)
        }
        return inode
    }

    public func statistics() throws(DiskError) -> VolumeStatistics {
        VolumeStatistics(
            blockSize: superblock.blockSize,
            totalBlocks: superblock.blockCount,
            freeBlocks: freeCounts.withLock { $0?.blocks } ?? superblock.freeBlocks,
            files: UInt64(superblock.inodeCount - (freeCounts.withLock { $0?.inodes } ?? superblock.freeInodes))
        )
    }
}
