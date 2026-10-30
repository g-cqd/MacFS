import AemiKernel
public import FSCore

/// A read-only Btrfs volume on one device.
///
/// Mounts the default subvolume. Nested subvolumes appear as directories; their inodes are told
/// apart from the mounted tree's by the tree number in the upper 32 bits of the node identifier.
public final class BtrfsFileSystem: ReadOnlyFileSystem {
    public let volume: VolumeDescription
    public let rootID: UInt64

    let trees: BtrfsTreeReader
    let mountedTree: UInt64
    private let treeRoots = BoundedCache<UInt64, UInt64>(capacity: 256)
    let extentCache = BoundedCache<UInt64, [BtrfsExtent]>(capacity: 512)
    let decodedCache = BoundedCache<UInt64, [UInt8]>(capacity: 64)

    /// Whether `source` carries a Btrfs superblock (magic only; mounting validates the rest).
    public static func probe(_ source: any BlockSource) -> (label: String, uuid: [UInt8])? {
        guard let raw = try? source.read(at: BtrfsSuperblock.offsets[0], count: BtrfsSuperblock.size),
            let superblock = try? BtrfsSuperblock(raw, at: BtrfsSuperblock.offsets[0])
        else { return nil }
        return (superblock.label, superblock.fsid)
    }

    public init(source: any BlockSource) throws(DiskError) {
        let superblock = try Self.newestSuperblock(source)
        var chunks = try ChunkMap.bootstrap(superblock.systemChunkArray, deviceID: superblock.deviceID)
        let bootstrap = BtrfsTreeReader(source: source, superblock: superblock, chunks: chunks)
        let chunkItems = try bootstrap.items(
            root: superblock.chunkTree,
            from: BtrfsKey(BtrfsItem.firstChunkTreeObject, BtrfsItem.chunkItem, 0),
            to: BtrfsKey(BtrfsItem.firstChunkTreeObject, BtrfsItem.chunkItem, .max))
        for item in chunkItems {
            try chunks.add(logical: item.key.offset, item: item.data, deviceID: superblock.deviceID)
        }
        trees = BtrfsTreeReader(source: source, superblock: superblock, chunks: chunks)
        mountedTree = try Self.defaultSubvolume(trees)
        rootID = BtrfsItem.firstFreeObject
        volume = VolumeDescription(
            format: "btrfs", label: superblock.label, uuid: superblock.fsid, caseRule: .sensitive,
            maximumNameLength: 255)
        _ = try treeRoot(mountedTree)
    }

    /// The valid superblock copy with the highest generation.
    private static func newestSuperblock(_ source: any BlockSource) throws(DiskError) -> BtrfsSuperblock {
        var best: BtrfsSuperblock?
        var firstError: DiskError?
        for offset in BtrfsSuperblock.offsets where offset + UInt64(BtrfsSuperblock.size) <= source.byteCount {
            do throws(DiskError) {
                let candidate = try BtrfsSuperblock(
                    try source.read(at: offset, count: BtrfsSuperblock.size), at: offset)
                if best.map({ candidate.generation > $0.generation }) ?? true { best = candidate }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        guard let best else { throw firstError ?? .corrupt("no Btrfs superblock") }
        return best
    }

    /// The subvolume the root tree's "default" entry names, or the top-level tree.
    private static func defaultSubvolume(_ trees: BtrfsTreeReader) throws(DiskError) -> UInt64 {
        let name = Array("default".utf8)
        let hash = UInt64(CRC32C.update(~1, name))
        let key = BtrfsKey(trees.superblock.rootDirectoryObject, BtrfsItem.dirItem, hash)
        guard let item = try trees.item(root: trees.superblock.rootTree, key),
            let entry = try BtrfsDirectoryItem.all(in: item).first(where: { $0.name == name })
        else { return BtrfsItem.fsTree }
        return entry.location.objectID
    }

    /// The root block of subvolume tree `tree`.
    func treeRoot(_ tree: UInt64) throws(DiskError) -> UInt64 {
        try treeRoots.value(for: tree) { () throws(DiskError) -> UInt64 in
            let items = try trees.items(
                root: trees.superblock.rootTree, from: BtrfsKey(tree, BtrfsItem.rootItem, 0),
                to: BtrfsKey(tree, BtrfsItem.rootItem, .max))
            guard let item = items.last else { throw .notFound }
            return try item.data.u64(176)
        }
    }

    // MARK: Node identifiers

    /// Mounted-tree inodes keep their number; other trees' put the tree in the upper 32 bits.
    func identifier(tree: UInt64, inode: UInt64) throws(DiskError) -> UInt64 {
        if tree == mountedTree { return inode }
        guard tree < 1 << 32, inode < 1 << 32 else { throw .unsupported("inode \(inode) of subvolume \(tree)") }
        return tree << 32 | inode
    }

    func location(_ id: UInt64) -> (tree: UInt64, inode: UInt64) {
        id >> 32 == 0 ? (mountedTree, id) : (id >> 32, id & 0xFFFF_FFFF)
    }

    public func statistics() throws(DiskError) -> VolumeStatistics {
        let superblock = trees.superblock
        let block = UInt64(superblock.sectorSize)
        return VolumeStatistics(
            blockSize: superblock.sectorSize, totalBlocks: superblock.totalBytes / block,
            freeBlocks: superblock.totalBytes.subtractingReportingOverflow(superblock.bytesUsed).partialValue / block,
            files: 0)
    }
}
