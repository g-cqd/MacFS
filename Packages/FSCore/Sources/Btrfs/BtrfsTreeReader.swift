import FSCore

/// Reads and searches trees: the chunk tree at mount, then the root tree and the subvolume trees.
struct BtrfsTreeReader: Sendable {
    struct Item: Sendable {
        let key: BtrfsKey
        let data: DiskBytes
    }

    let source: any BlockSource
    let superblock: BtrfsSuperblock
    let chunks: ChunkMap
    private let cache: BoundedCache<UInt64, BtrfsNode>

    init(source: any BlockSource, superblock: BtrfsSuperblock, chunks: ChunkMap) {
        self.source = source
        self.superblock = superblock
        self.chunks = chunks
        // 16 MiB of 16 KiB nodes.
        self.cache = BoundedCache(capacity: max(64, (16 << 20) / superblock.nodeSize))
    }

    func node(_ logical: UInt64) throws(DiskError) -> BtrfsNode {
        try cache.value(for: logical) { () throws(DiskError) -> BtrfsNode in
            let size = superblock.nodeSize
            let physical = try chunks.physical(logical, length: UInt64(size))
            return try BtrfsNode(try source.read(at: physical, count: size), at: logical, superblock: superblock)
        }
    }

    /// Every item with `low <= key <= high` in the tree rooted at `root`, in key order, at most `limit`.
    ///
    /// Depth-first over an explicit stack (no recursion: tree depth is on-disk data). A child must be
    /// exactly one level below its parent, which bounds the walk at eight levels even on a hostile image.
    func items(root: UInt64, from low: BtrfsKey, to high: BtrfsKey, limit: Int = .max) throws(DiskError) -> [Item] {
        var found: [Item] = []
        var pending: [(address: UInt64, level: UInt8?)] = [(root, nil)]
        while let (address, expected) = pending.popLast() {
            let node = try node(address)
            if let expected, node.level != expected {
                throw .corrupt("tree block at \(address) is at level \(node.level), not \(expected)")
            }
            if node.level == 0 {
                // Keys are sorted: start at the first item not below `low`, stop at the first above `high`.
                var index = try node.firstIndex(where:) { (key) throws(DiskError) -> Bool in key >= low }
                while index < node.count {
                    let key = try node.key(index)
                    if key > high { return found }
                    found.append(Item(key: key, data: try node.itemData(index)))
                    if found.count >= limit { return found }
                    index += 1
                }
                continue
            }
            // Child i holds keys from key(i) up to key(i + 1): start at the last child whose first key is not above `low`.
            var children: [UInt64] = []
            var index = max(0, try node.firstIndex(where:) { (key) throws(DiskError) -> Bool in key > low } - 1)
            while index < node.count, try node.key(index) <= high {
                children.append(try node.child(index))
                index += 1
            }
            // Pushed in reverse so the leftmost child is visited first.
            for child in children.reversed() { pending.append((child, node.level - 1)) }
        }
        return found
    }

    /// The item with exactly `key`, if any.
    func item(root: UInt64, _ key: BtrfsKey) throws(DiskError) -> DiskBytes? {
        try items(root: root, from: key, to: key, limit: 1).first?.data
    }
}
