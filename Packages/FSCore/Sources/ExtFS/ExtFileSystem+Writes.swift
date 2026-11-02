public import FSCore
import Synchronization

/// ext2 writes, first slice (roadmap 0026, ADR-0018): bytes overwritten inside a file's existing blocks. A volume without a
/// journal follows Linux's own model: marked not clean while writable, clean at `close`; a crash leaves it for e2fsck, so a
/// volume not clean is refused. Data is written before the inode that records the change, and nothing is flushed until
/// `synchronize` or `close`.
extension ExtFileSystem: WritableFileSystem {
    /// `s_state`'s bits: cleanly unmounted, and errors detected.
    static let validState: UInt16 = 0x0001
    static let errorState: UInt16 = 0x0002
    /// Read-only-compatible features this writer leaves correct: sparse_super, large_file, btree_dir, huge_file, gdt_csum
    /// (no descriptor changes yet), dir_nlink, extra_isize, quota and project (no usage changes yet), bigalloc.
    static let writableROCompat: UInt32 =
        0x0001 | 0x0002 | 0x0004 | 0x0008 | 0x0010 | 0x0020 | 0x0040 | 0x0100 | 0x0200
        | 0x2000

    /// Opens `device` writable: refuses, by name, what this writer does not maintain, then marks the volume not clean.
    public convenience init(
        writable device: any WritableBlockSource,
        clock: @escaping @Sendable () -> Timestamp
    ) throws(DiskError) {
        try self.init(source: device, clock: clock)
        try beginWriting(on: device)
    }

    /// Starts writing on `device`, the one this volume reads (ADR-0018): refuses, by name, what this writer does not
    /// maintain, then marks the volume not clean. A mount path calls it at activation, when the mount was not asked to be
    /// read-only. Once only.
    public func beginWriting(on device: any WritableBlockSource) throws(DiskError) {
        try serialized { () throws(DiskError) in
            guard writingDevice.withLock({ $0 == nil }), !closed.withLock({ $0 }) else {
                throw .unsupported("this volume already writes, or was closed")
            }
            // A device opened read-only refuses the mount's first write: ``DiskError/readOnly``.
            let bytes = DiskBytes(try device.read(at: ExtSuperblock.offset, count: ExtSuperblock.size))
            if try bytes.u32(0x5C) & 0x0004 != 0 || superblock.incompat & 0x0004 != 0 {
                throw .unsupported("writing a volume with a journal (ext3/ext4)")
            }
            if superblock.hasMetadataChecksums { throw .unsupported("writing a volume with metadata checksums") }
            if superblock.incompat & 0x0100 != 0 {
                throw .unsupported("writing a volume with multiple-mount protection")
            }
            let roCompat = try bytes.u32(0x64)
            let unknown = roCompat & ~Self.writableROCompat
            guard unknown == 0 else {
                throw .unsupported("writing a volume with read-only features 0x\(String(unknown, radix: 16))")
            }
            let state = try bytes.u16(0x3A)
            guard state & Self.validState != 0, state & Self.errorState == 0 else {
                throw .unsupported("writing a volume not cleanly unmounted: run e2fsck")
            }
            // The mount: not clean until `close`, one more mount, its time; durable before any change.
            let mounts = UInt16(truncatingIfNeeded: Int(try bytes.u16(0x34)) + 1)
            try markSuperblock(on: device, state: state & ~Self.validState, time: 0x2C) {
                Self.put16(mounts, at: 0x34, in: &$0)
            }
            writingDevice.withLock { $0 = device }
        }
    }

    public func write(_ id: UInt64, at offset: UInt64, _ bytes: [UInt8]) throws(DiskError) {
        try serialized { () throws(DiskError) in
            let device = try openDevice()
            let inode = try regularFile(id, "writing")
            guard !bytes.isEmpty else { return }
            let end = offset + UInt64(bytes.count)
            let blockSize = UInt64(superblock.blockSize)
            let runs = try runs(inode, through: (end - 1) / blockSize)
            if end <= inode.size, let pieces = Self.pieces(of: runs, from: offset, to: end, blockSize: blockSize) {
                for piece in pieces { try device.write(at: piece.at, Array(bytes[piece.from ..< piece.to])) }
                try touch(inode, on: device)
                return
            }
            try freeCounts.withLock { (free) throws(DiskError) in
                free = try allocatingWrite(
                    inode,
                    at: offset,
                    bytes,
                    length: UInt64(bytes.count),
                    on: device,
                    free: free ?? initialFreeCounts
                )
            }
        }
    }

    /// Where the bytes `from ..< to` of a file lie on disk, as (device offset, range in the bytes); nil when a block in the range
    /// is not stored: a hole, an unwritten extent, or a gap between extents.
    static func pieces(
        of runs: [ExtRun],
        from offset: UInt64,
        to end: UInt64,
        blockSize: UInt64
    ) -> [(at: UInt64, from: Int, to: Int)]? {
        var covered = offset
        var pieces: [(at: UInt64, from: Int, to: Int)] = []
        for run in runs where run.end * blockSize > offset && run.logical * blockSize < end {
            let from = max(offset, run.logical * blockSize)
            guard from == covered, let physical = run.physical else { return nil }
            let to = min(end, run.end * blockSize)
            pieces.append(
                (physical * blockSize + (from - run.logical * blockSize), Int(from - offset), Int(to - offset))
            )
            covered = to
        }
        return covered >= end ? pieces : nil
    }

    public func synchronize() throws(DiskError) {
        try serialized { () throws(DiskError) in
            try openDevice().flush()
        }
    }

    public func close() throws(DiskError) {
        try serialized { () throws(DiskError) in
            let device = try openDevice()
            // Every change durable before the volume says clean.
            try device.flush()
            let state = try DiskBytes(try device.read(at: ExtSuperblock.offset, count: ExtSuperblock.size)).u16(0x3A)
            let free = freeCounts.withLock { $0 }
            let wide = superblock.is64Bit
            try markSuperblock(on: device, state: state | Self.validState, time: 0x30) { raw in
                // The free counts the session's changes left, as Linux writes them: lazily, at the unmount.
                guard let free else { return }
                Self.put32(UInt32(truncatingIfNeeded: free.blocks), at: 0x0C, in: &raw)
                if wide { Self.put32(UInt32(truncatingIfNeeded: free.blocks >> 32), at: 0x158, in: &raw) }
                Self.put32(free.inodes, at: 0x10, in: &raw)
            }
            closed.withLock { $0 = true }
        }
    }

    /// The superblock with `s_state` set to `state` and the time at `time` (`s_mtime` at the mount, `s_wtime` at the unmount),
    /// written and flushed.
    private func markSuperblock(
        on device: any WritableBlockSource,
        state: UInt16,
        time: Int,
        _ more: (inout [UInt8]) -> Void = { _ in }
    ) throws(DiskError) {
        var raw = try device.read(at: ExtSuperblock.offset, count: ExtSuperblock.size)
        Self.put16(state, at: 0x3A, in: &raw)
        Self.put32(UInt32(truncatingIfNeeded: clock().seconds), at: time, in: &raw)
        more(&raw)
        try device.write(at: ExtSuperblock.offset, raw)
        try device.flush()
    }

    /// File `id`, if its bytes are stored in blocks this writer maps: a regular file, neither inline nor encrypted. `verb`
    /// names what was refused.
    func regularFile(_ id: UInt64, _ verb: String) throws(DiskError) -> ExtInode {
        let inode = try inode(id)
        guard inode.kind != .directory else { throw .isDirectory }
        guard inode.kind == .regular else { throw .unsupported("\(verb) a \(inode.kind)") }
        guard inode.flags & (ExtInode.inlineDataFlag | ExtInode.encryptedFlag) == 0 else {
            throw .unsupported("\(verb) an inline or encrypted file")
        }
        return inode
    }

    /// The inode's block pointers, size and 512-byte sectors set, with its change and modification times.
    func touchMapping(
        _ inode: ExtInode,
        pointers: [UInt32],
        size: UInt64,
        sectors: UInt64,
        on device: any WritableBlockSource
    ) throws(DiskError) {
        try touch(inode, on: device) { raw in
            for (index, pointer) in pointers.enumerated() { Self.put32(pointer, at: 0x28 + index * 4, in: &raw) }
            Self.put32(UInt32(truncatingIfNeeded: size), at: 0x04, in: &raw)
            Self.put32(UInt32(truncatingIfNeeded: size >> 32), at: 0x6C, in: &raw)
            Self.put32(UInt32(sectors), at: 0x1C, in: &raw)
        }
    }

    /// The free counts as the volume had them when it was opened.
    var initialFreeCounts: ExtFreeCounts { ExtFreeCounts(blocks: superblock.freeBlocks, inodes: superblock.freeInodes) }

    /// The device, unless the volume is read-only or closed.
    func openDevice() throws(DiskError) -> any WritableBlockSource {
        guard let device = writingDevice.withLock({ $0 }), !closed.withLock({ $0 }) else { throw .readOnly }
        return device
    }

    /// The inode's `times` (change and modification by default) set to now, with their nanoseconds where the inode has room.
    func touch(
        _ inode: ExtInode,
        on device: any WritableBlockSource,
        times: [(Int, Int)] = [(0x0C, 0x84), (0x10, 0x88)],
        _ more: (inout [UInt8]) -> Void = { _ in }
    ) throws(DiskError) {
        let location = try inodeLocation(inode.number)
        let blockSize = UInt64(superblock.blockSize)
        let at = location.block * blockSize + UInt64(location.offset)
        var raw = try device.read(at: at, count: superblock.inodeSize)
        let (low, extra) = Self.stamp(clock())
        for (field, extraField) in times {
            Self.put32(low, at: field, in: &raw)
            if 128 + inode.extraSize >= extraField + 4 { Self.put32(extra, at: extraField, in: &raw) }
        }
        more(&raw)
        try device.write(at: at, raw)
        blocks.invalidate(location.block)
    }

    /// A time as an inode keeps it: the low 32 bits of the seconds, and the `_extra` word (two epoch bits, the nanoseconds).
    static func stamp(_ time: Timestamp) -> (low: UInt32, extra: UInt32) {
        let low = UInt32(truncatingIfNeeded: time.seconds)
        let epoch = UInt32(truncatingIfNeeded: (time.seconds - Int64(Int32(bitPattern: low))) >> 32) & 3
        return (low, epoch | UInt32(time.nanoseconds) << 2)
    }

    static func put16(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for index in 0 ..< 4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}
