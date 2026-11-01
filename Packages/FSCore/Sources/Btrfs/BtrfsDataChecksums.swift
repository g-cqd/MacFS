import FSCore

/// Data checksums from the csum tree, as Linux verifies them (fs/btrfs/file-item.c, `btrfs_lookup_bio_sums`; inode.c,
/// `btrfs_check_sector_csum`): one checksum per sector of an extent's on-disk bytes, in items keyed by the logical address
/// where their run starts. A compressed extent's checksums cover its compressed bytes. A sector without a checksum is an error,
/// as in Linux, unless the inode is NODATASUM (the caller skips those).
///
/// Linux verifies when data comes from the disk and trusts its page cache after; here a piece of an extent (1 MiB) is verified
/// on its first read and remembered (a bounded cache), so a warm read pays nothing (docs/conformance/performance.md).
final class BtrfsDataChecksums: Sendable {
    static let piece: UInt64 = 1 << 20

    let root: UInt64?
    private let trees: BtrfsTreeReader
    private let verified = BoundedCache<UInt64, Bool>(capacity: 1 << 16)

    init(trees: BtrfsTreeReader, root: UInt64?) {
        self.trees = trees
        self.root = root
    }

    private var sector: UInt64 { UInt64(trees.superblock.sectorSize) }
    private var kind: BtrfsChecksum { trees.superblock.checksum }

    /// The checksums of `sectors` sectors from `logical`, in order. Throws when one has none.
    private func expected(_ logical: UInt64, sectors: Int) throws(DiskError) -> [ArraySlice<UInt8>] {
        guard let root else { throw .checksum("no checksum tree for data at \(logical)") }
        let size = kind.size
        // An item covers at most a node's worth of checksums: search back that far for the one that holds `logical`.
        let reach = UInt64(trees.superblock.nodeSize / size) * sector
        let low = logical > reach ? logical - reach : 0
        let items = try trees.items(
            root: root,
            from: BtrfsKey(BtrfsItem.checksumObject, BtrfsItem.extentChecksum, low),
            to: BtrfsKey(BtrfsItem.checksumObject, BtrfsItem.extentChecksum, logical + UInt64(sectors) * sector - 1)
        )
        var sums: [ArraySlice<UInt8>?] = Array(repeating: nil, count: sectors)
        for item in items {
            let count = item.data.count / size
            for index in 0 ..< count {
                let address = item.key.offset + UInt64(index) * sector
                guard address >= logical else { continue }
                let slot = Int((address - logical) / sector)
                guard slot < sectors else { break }
                sums[slot] = try item.data.region(index * size, size)
            }
        }
        var result: [ArraySlice<UInt8>] = []
        for (slot, sum) in sums.enumerated() {
            guard let sum else { throw .checksum("no checksum for the sector at \(logical + UInt64(slot) * sector)") }
            result.append(sum)
        }
        return result
    }

    /// Every sector of `bytes`, read from `logical`, against its stored checksum.
    private func check(_ bytes: UnsafeRawBufferPointer, at logical: UInt64) throws(DiskError) {
        let sectorBytes = Int(sector)
        let count = bytes.count
        guard count % sectorBytes == 0 else { throw .corrupt("data extent of \(count) bytes, not whole sectors") }
        let sums = try expected(logical, sectors: count / sectorBytes)
        for (index, sum) in sums.enumerated() {
            let start = index * sectorBytes
            let piece = unsafe UnsafeRawBufferPointer(rebasing: bytes[start ..< start + sectorBytes])
            guard unsafe kind.matches(piece, stored: sum) else {
                throw .checksum("data sector at \(logical + UInt64(start))")
            }
        }
    }

    private func check(_ bytes: [UInt8], at logical: UInt64) throws(DiskError) {
        var failure: DiskError?
        bytes.withUnsafeBytes { raw in
            do throws(DiskError) { try unsafe check(raw, at: logical) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    /// The pieces of the extent [`diskStart`, +`diskLength`) that the read [`from`, +`count`) touches, each verified once.
    /// `read` holds those bytes when the caller has them: a piece the read covers whole is checked there, not read again.
    func verify(
        diskStart: UInt64,
        diskLength: UInt64,
        from: UInt64,
        count: UInt64,
        read: UnsafeRawBufferPointer? = nil
    ) throws(DiskError) {
        guard count > 0, from >= diskStart, from + count <= diskStart + diskLength else {
            throw .corrupt("a read of \(count) bytes at \(from) outside its extent")
        }
        var index = (from - diskStart) / Self.piece
        let last = (from + count - 1 - diskStart) / Self.piece
        while index <= last {
            let start = diskStart + index * Self.piece
            let length = min(Self.piece, diskStart + diskLength - start)
            // Through `value(for:)`: concurrent readers of one piece wait for one verification instead of each doing it.
            _ = try verified.value(for: start) { () throws(DiskError) -> Bool in
                if let read = unsafe read, start >= from, start + length <= from + count {
                    let offset = Int(start - from)
                    try unsafe check(UnsafeRawBufferPointer(rebasing: read[offset ..< offset + Int(length)]), at: start)
                } else {
                    let physical = try trees.chunks.physical(start, length: length)
                    try check(try trees.source.read(at: physical, count: Int(length)), at: start)
                }
                return true
            }
            index += 1
        }
    }

    /// A compressed extent's on-disk bytes, before they are decoded (decoded extents are cached, so this runs once each).
    func verify(compressed bytes: [UInt8], at logical: UInt64) throws(DiskError) {
        try check(bytes, at: logical)
    }
}
