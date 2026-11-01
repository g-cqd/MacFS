import AemiKernel
import FSCore

/// Logical to physical address translation for one device (`struct btrfs_chunk`).
///
/// Every tree block and data extent is addressed logically. A chunk maps a logical range to one or
/// more stripes; a mount of one device can only read chunks that keep a whole copy on it: SINGLE,
/// DUP and the RAID1 family. Striped profiles fail when they are read, not at mount, so a volume
/// whose metadata is mirrored but whose data is striped still lists.
struct ChunkMap: Sendable {
    private struct Chunk: Sendable {
        let logical: UInt64
        let length: UInt64
        /// Where this device holds a full copy, or why it cannot be read.
        let physical: Result<UInt64, DiskError>
    }

    private static let stripedProfiles: UInt64 = (1 << 3) | (1 << 6) | (1 << 7) | (1 << 8)
    private var chunks: [Chunk] = []

    /// Adds the chunk item `item` whose key offset is `logical`.
    mutating func add(logical: UInt64, item: DiskBytes, deviceID: UInt64) throws(DiskError) {
        let length = try item.u64(0)
        let type = try item.u64(24)
        let stripes = Int(try item.u16(44))
        guard length > 0, stripes > 0, logical.checkedAdding(length) != nil else {
            throw .corrupt("chunk at \(logical): length \(length), \(stripes) stripes")
        }
        var physical: Result<UInt64, DiskError> = .failure(
            .unsupported("chunk at \(logical) has no copy on this device")
        )
        if type & Self.stripedProfiles != 0, stripes > 1 {
            physical = .failure(.unsupported("striped chunk at \(logical) (profile \(type))"))
        } else {
            for index in 0 ..< stripes where try item.u64(48 + 32 * index) == deviceID {
                physical = .success(try item.u64(48 + 32 * index + 8))
                break
            }
        }
        if chunks.contains(where: { $0.logical == logical }) { return }
        chunks.append(Chunk(logical: logical, length: length, physical: physical))
        chunks.sort { $0.logical < $1.logical }
    }

    /// The physical offset of `length` bytes at `logical`. The range must lie inside one chunk,
    /// which the format guarantees for tree blocks and extents.
    func physical(_ logical: UInt64, length: UInt64) throws(DiskError) -> UInt64 {
        guard let index = chunks.lastIndex(atOrBefore: logical, by: \.logical) else {
            throw .corrupt("logical address \(logical) is in no chunk")
        }
        let chunk = chunks[index]
        let delta = logical - chunk.logical
        guard let end = delta.checkedAdding(length), end <= chunk.length else {
            throw .corrupt("range \(logical)+\(length) crosses the end of its chunk")
        }
        return try chunk.physical.get() + delta
    }

    /// Parses the superblock's bootstrap array: (key, chunk item) pairs for the system chunks.
    static func bootstrap(_ array: DiskBytes, deviceID: UInt64) throws(DiskError) -> ChunkMap {
        var map = ChunkMap()
        var cursor = 0
        while cursor < array.count {
            let key = try BtrfsKey(array, at: cursor)
            guard key.type == BtrfsItem.chunkItem else { throw .corrupt("system chunk array holds type \(key.type)") }
            let stripes = Int(try array.u16(cursor + BtrfsKey.size + 44))
            let size = 48 + 32 * stripes
            try map.add(logical: key.offset, item: try array.slice(cursor + BtrfsKey.size, size), deviceID: deviceID)
            cursor += BtrfsKey.size + size
        }
        return map
    }
}
