import FSCore

/// ext4's metadata checksums (`metadata_csum`), as Linux computes them in fs/ext4: `ext4_group_desc_csum`, `ext4_inode_csum`,
/// `ext4_extent_block_csum` and `ext4_dirblock_csum`. Each is raw CRC-32C (no inversion) from the file system's seed, or from
/// an inode's own seed (the file system's, then the inode number and generation). A stored checksum field counts as zero.
///
/// CRC-32C runs left to right, so a seed followed by more bytes is one call over both: the inode's checksum is one CRC over
/// [number, generation, the inode with its checksum fields zeroed], copied to the stack. Six calls with small arrays cost
/// fsprobe 8% on ext4 (roadmap 0015).
struct ExtChecksums: Sendable {
    let seed: UInt32
    /// CRC-32C from `start` over `words` little-endian words of `head`, then `bytes`, with the two-byte fields at `zero` and
    /// `alsoZero` (offsets into `bytes`) counted as zero: one call over a stack copy, nothing allocated.
    private static func crc(
        _ start: UInt32,
        head: (UInt32, UInt32),
        words: Int,
        _ bytes: ArraySlice<UInt8>,
        zero: Int? = nil,
        alsoZero: Int? = nil
    ) -> UInt32 {
        let body = 4 * words
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: body + bytes.count) { buffer in
            for byte in 0 ..< body {
                let word = byte < 4 ? head.0 : head.1
                unsafe buffer[byte] = UInt8(truncatingIfNeeded: word >> (8 * (byte % 4)))
            }
            bytes.withUnsafeBufferPointer { source in
                guard let from = source.baseAddress, let to = buffer.baseAddress else { return }
                unsafe (to + body).update(from: from, count: source.count)
            }
            for field in [zero, alsoZero] {
                guard let field else { continue }
                unsafe buffer[body + field] = 0
                unsafe buffer[body + field + 1] = 0
            }
            return unsafe CRC32C.update(start, UnsafeBufferPointer(buffer))
        }
    }

    /// The seed of every checksum of one inode's metadata.
    func inodeSeed(number: UInt64, generation: UInt32) -> UInt32 {
        Self.crc(seed, head: (UInt32(truncatingIfNeeded: number), generation), words: 2, [][...])
    }

    /// A group descriptor (its `bg_checksum` at 0x1E is the low 16 bits).
    func verifyDescriptor(_ raw: DiskBytes, group: UInt32) throws(DiskError) {
        let value = Self.crc(seed, head: (group, 0), words: 1, try raw.region(0, raw.count), zero: 0x1E)
        guard UInt16(truncatingIfNeeded: value) == (try raw.u16(0x1E)) else {
            throw .checksum("group descriptor \(group)")
        }
    }

    /// An inode (`i_checksum_lo` at 0x7C, and `i_checksum_hi` at 0x82 when the extra size covers it; without it, only the
    /// low 16 bits are stored).
    func verifyInode(_ raw: DiskBytes, number: UInt64, generation: UInt32, extraSize: Int) throws(DiskError) {
        let wide = raw.count > 128 && extraSize >= 4
        let value = Self.crc(
            seed,
            head: (UInt32(truncatingIfNeeded: number), generation),
            words: 2,
            try raw.region(0, raw.count),
            zero: 0x7C,
            alsoZero: wide ? 0x82 : nil
        )
        var stored = UInt32(try raw.u16(0x7C))
        if wide { stored |= UInt32(try raw.u16(0x82)) << 16 }
        guard (wide ? value : value & 0xFFFF) == stored else { throw .checksum("inode \(number)") }
    }

    /// An extent tree block outside the inode: the checksum follows `eh_max` entries.
    func verifyExtentBlock(_ block: DiskBytes, inode: UInt64, seed: UInt32) throws(DiskError) {
        let tail = 12 + 12 * Int(try block.u16(4))
        guard tail + 4 <= block.count else {
            throw .corrupt("inode \(inode): extent block without room for its checksum")
        }
        guard CRC32C.update(seed, try block.region(0, tail)) == (try block.u32(tail)) else {
            throw .checksum("inode \(inode): extent block")
        }
    }

    /// A directory block, as Linux's `__ext4_read_dirblock` tells them apart. In an indexed directory, logical block 0 and any
    /// block whose first entry spans it are index blocks, checked by their `dx_tail` (`ext4_dx_csum`). Every other block is a
    /// leaf: a 12-byte tail entry (inode 0, length 12, type 0xDE) holds the checksum of what precedes it, and a leaf without
    /// one is refused. The kind is decided by position, not by the last bytes: a root the kernel made from a full linear block
    /// keeps that block's old tail bytes in `dt_reserved` (roadmap 0016).
    func verifyDirectoryBlock(
        _ block: DiskBytes,
        directory: UInt64,
        logical: UInt64,
        seed: UInt32,
        indexed: Bool
    ) throws(DiskError) {
        if indexed, let countOffset = try Self.indexCountOffset(block, logical: logical, directory: directory) {
            return try verifyIndexBlock(block, countOffset: countOffset, directory: directory, seed: seed)
        }
        let tail = block.count - 12
        guard tail >= 0 else { throw .corrupt("directory \(directory): block of \(block.count) bytes") }
        let (inode, length) = (try block.u32(tail), try block.u16(tail + 4))
        let (nameLength, type) = (try block.u8(tail + 6), try block.u8(tail + 7))
        guard inode == 0, length == 12, nameLength == 0, type == 0xDE else {
            throw .checksum("directory \(directory): block without a checksum tail")
        }
        guard CRC32C.update(seed, try block.region(0, tail)) == (try block.u32(tail + 8)) else {
            throw .checksum("directory \(directory): block")
        }
    }

    /// Where an index block's `dx_countlimit` sits (8 in an interior node, after the fake entry; 32 in the root, after ".",
    /// ".." and `dx_root_info`), or nil for a leaf (`get_dx_countlimit`).
    static func indexCountOffset(_ block: DiskBytes, logical: UInt64, directory: UInt64) throws(DiskError) -> Int? {
        let first = recordLength(try block.u16(4), blockSize: block.count)
        if first == block.count { return 8 }
        guard logical == 0 else { return nil }
        let (dotLength, dot) = (try block.u8(6), try block.u8(8))
        let (dotDot, dotDotLength) = (try block.u16(16), try block.u8(18))
        let (reserved, infoLength) = (try block.u32(24), try block.u8(29))
        let isRoot =
            first == 12 && dotLength == 1 && dot == 0x2E && dotDotLength == 2
            && recordLength(dotDot, blockSize: block.count) == block.count - 12 && reserved == 0 && infoLength == 8
        guard isRoot else { throw .corrupt("directory \(directory): an htree whose first block is not its root") }
        return 32
    }

    /// `ext4_rec_len_from_disk`: lengths of 64 KiB blocks do not fit 16 bits.
    static func recordLength(_ stored: UInt16, blockSize: Int) -> Int {
        guard blockSize >= 65536 else { return Int(stored) }
        if stored == 0xFFFF || stored == 0 { return blockSize }
        return Int(stored & 0xFFFC) | Int(stored & 3) << 16
    }

    /// `ext4_dx_csum`: CRC-32C over the block up to the last used entry, then `dt_reserved`, then a zero checksum field. The
    /// tail follows `limit` entries, used or not.
    private func verifyIndexBlock(
        _ block: DiskBytes,
        countOffset: Int,
        directory: UInt64,
        seed: UInt32
    ) throws(DiskError) {
        let (limit, count) = (Int(try block.u16(countOffset)), Int(try block.u16(countOffset + 2)))
        let tail = countOffset + 8 * limit
        guard count <= limit, tail + 8 <= block.count else {
            throw .checksum("directory \(directory): index block without room for its checksum")
        }
        var value = CRC32C.update(seed, try block.region(0, countOffset + 8 * count))
        value = CRC32C.update(value, try block.region(tail, 4))
        value = CRC32C.update(value, [0, 0, 0, 0][...])
        guard value == (try block.u32(tail + 4)) else { throw .checksum("directory \(directory): index block") }
    }
}
