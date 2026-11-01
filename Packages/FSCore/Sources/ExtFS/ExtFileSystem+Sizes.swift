public import FSCore
import Synchronization

/// ext2 sizes and attributes (roadmap 0026 step 3). A truncation clears the pointers past the new end and zeroes the rest of
/// its last block, flushed, then frees the blocks: a crash leaves at worst blocks marked used that nothing points to.
extension ExtFileSystem {
    public func setSize(_ id: UInt64, to size: UInt64) throws(DiskError) {
        let device = try openDevice()
        let inode = try regularFile(id, "sizing")
        guard inode.flags & ExtInode.extentsFlag == 0 else {
            throw .unsupported("sizing an extent-mapped file (a later slice)")
        }
        let blockSize = UInt64(superblock.blockSize)
        try freeCounts.withLock { (free) throws(DiskError) in
            var allocation = try allocation(for: inode, on: device, free: free ?? initialFreeCounts)
            var freed: [UInt64] = []
            var changed: [(UInt64, [UInt8])] = []
            if size < inode.size {
                let keep = (size + blockSize - 1) / blockSize
                for index in 0 ..< 12 where UInt64(index) >= keep && allocation.pointers[index] != 0 {
                    freed.append(UInt64(allocation.pointers[index]))
                    allocation.pointers[index] = 0
                }
                var base: UInt64 = 12
                var span = blockSize / 4
                for slot in 12 ... 14 {
                    let top = UInt64(allocation.pointers[slot])
                    if top != 0,
                        try prune(top, depth: slot - 11, base: base, keep: keep, freed: &freed, changed: &changed)
                    {
                        allocation.pointers[slot] = 0
                    }
                    base += span
                    span *= blockSize / 4
                }
            }
            // The rest of the new last block reads as zeros, whether the file shrinks to it or grows past it.
            try zeroTail(of: inode, from: min(size, inode.size), on: device)
            for (block, bytes) in changed { try device.write(at: block * blockSize, bytes) }
            let sectors = inode.sectors - UInt64(freed.count) * blockSize / 512
            try touchMapping(inode, pointers: allocation.pointers, size: size, sectors: sectors, on: device)
            if !freed.isEmpty {
                try device.flush()
                for block in freed { try allocation.free(block: block) }
                try writeAllocation(allocation, on: device)
            }
            for (block, _) in changed { blocks.invalidate(block) }
            for block in allocation.metadata.keys { blocks.invalidate(block) }
            mappings.invalidate(id)
            free = allocation.free
        }
    }

    public func setAttributes(_ id: UInt64, _ changes: AttributeChanges) throws(DiskError) {
        let device = try openDevice()
        let inode = try inode(id)
        var times: [(Timestamp, Int, Int)] = []
        if let accessed = changes.accessed { times.append((accessed, 0x08, 0x8C)) }
        if let modified = changes.modified { times.append((modified, 0x10, 0x88)) }
        let extraSize = inode.extraSize
        try touch(inode, on: device, times: [(0x0C, 0x84)]) { raw in
            if let mode = changes.mode { Self.put16(inode.mode & 0o170000 | mode & 0o7777, at: 0x00, in: &raw) }
            if let uid = changes.uid {
                Self.put16(UInt16(truncatingIfNeeded: uid), at: 0x02, in: &raw)
                Self.put16(UInt16(truncatingIfNeeded: uid >> 16), at: 0x78, in: &raw)
            }
            if let gid = changes.gid {
                Self.put16(UInt16(truncatingIfNeeded: gid), at: 0x18, in: &raw)
                Self.put16(UInt16(truncatingIfNeeded: gid >> 16), at: 0x7A, in: &raw)
            }
            for (time, field, extraField) in times {
                let (low, extra) = Self.stamp(time)
                Self.put32(low, at: field, in: &raw)
                if 128 + extraSize >= extraField + 4 { Self.put32(extra, at: extraField, in: &raw) }
            }
        }
    }

    // MARK: Pieces

    /// The subtree of indirect block `block` (`depth` levels, mapping the file's blocks from `base`) cut at `keep`: the data
    /// and indirect blocks past it added to `freed`, the kept part's cleared pointers to `changed`. True when the whole
    /// subtree goes.
    private func prune(
        _ block: UInt64,
        depth: Int,
        base: UInt64,
        keep: UInt64,
        freed: inout [UInt64],
        changed: inout [(UInt64, [UInt8])]
    ) throws(DiskError) -> Bool {
        let perBlock = UInt64(superblock.blockSize / 4)
        let childSpan = (1 ..< depth).reduce(UInt64(1)) { span, _ in span * perBlock }
        guard base < keep else {
            freed += try subtree(block, depth: depth)
            return true
        }
        var bytes = try self.block(block).bytes(0, superblock.blockSize)
        var touched = false
        for index in 0 ..< Int(perBlock) {
            let childBase = base + UInt64(index) * childSpan
            let child = UInt64(try DiskBytes(bytes).u32(index * 4))
            guard child != 0, childBase + childSpan > keep else { continue }
            let gone =
                depth == 1
                ? {
                    freed.append(child)
                    return true
                }()
                : try prune(child, depth: depth - 1, base: childBase, keep: keep, freed: &freed, changed: &changed)
            if gone {
                Self.put32(0, at: index * 4, in: &bytes)
                touched = true
            }
        }
        if touched { changed.append((block, bytes)) }
        return false
    }

    /// Every block of the subtree under indirect block `block`: its data blocks and its indirect blocks.
    private func subtree(_ block: UInt64, depth: Int) throws(DiskError) -> [UInt64] {
        let bytes = try self.block(block)
        var blocks = [block]
        for index in 0 ..< superblock.blockSize / 4 {
            let child = UInt64(try bytes.u32(index * 4))
            guard child != 0 else { continue }
            blocks += depth == 1 ? [child] : try subtree(child, depth: depth - 1)
        }
        return blocks
    }

    /// Zeros from byte `offset` of the file to the end of the block it falls in, if that block is stored.
    func zeroTail(of inode: ExtInode, from offset: UInt64, on device: any WritableBlockSource) throws(DiskError) {
        let blockSize = UInt64(superblock.blockSize)
        guard offset % blockSize != 0 else { return }
        let logical = offset / blockSize
        guard
            let run = try runs(inode).first(where: { $0.logical <= logical && logical < $0.end }),
            let physical = run.physical
        else { return }
        let at = (physical + logical - run.logical) * blockSize + offset % blockSize
        try device.write(at: at, [UInt8](repeating: 0, count: Int(blockSize - offset % blockSize)))
    }
}
