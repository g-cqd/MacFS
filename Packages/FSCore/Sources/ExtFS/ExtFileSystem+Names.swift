public import FSCore
import Synchronization

/// ext2 names (roadmap 0026 step 3): files and directories created and removed in linear directories.
///
/// The order is the one e2fsck's preen repairs after a crash (measured on every crash state). A create writes the blocks nothing
/// points to yet and the bitmaps, flushes, adds the name, flushes, then writes the inode: a crash leaves at worst leaked blocks
/// or a name for an unused inode. Not the inode before the name: preen does not reconnect an unconnected directory. A remove frees the inode first, flushes, then
/// drops the name: a crash between leaves a name for a deleted inode. Preen clears both.
extension ExtFileSystem {
    public func create(
        _ name: [UInt8],
        kind: NodeKind,
        in directory: UInt64,
        mode: UInt16,
        owner: (uid: UInt32, gid: UInt32)
    ) throws(DiskError) -> UInt64 {
        let device = try openDevice()
        try Self.validate(name)
        let parent = try changeableDirectory(directory)
        guard kind == .regular || kind == .directory else { throw .unsupported("creating a \(kind) (a later slice)") }
        if (try? lookup(name, in: directory)) != nil { throw .exists }
        if kind == .directory, parent.linkCount >= 32_000 { throw .unsupported("a directory with 32000 links") }
        return try freeCounts.withLock { (free) throws(DiskError) -> UInt64 in
            var allocation = try allocation(for: parent, on: device, free: free ?? initialFreeCounts)
            let group = (directory - 1) / UInt64(superblock.inodesPerGroup)
            let number = try allocation.allocateInode(near: group, directory: kind == .directory)
            let blockSize = UInt64(superblock.blockSize)
            // Phase one: the blocks nothing points to yet (a directory's first block, a block the parent grows by) and the
            // bitmaps; flushed, then the inode, which points to them, flushed: an unattached inode is still checked.
            var own = [UInt32](repeating: 0, count: 15)
            var firstBlock: (UInt64, [UInt8])?
            if kind == .directory {
                allocation.goal = superblock.firstDataBlock + group * UInt64(superblock.blocksPerGroup)
                let block = try allocation.allocate()
                own[0] = UInt32(block)
                firstBlock = (
                    block,
                    ExtDirectoryEntries.firstBlock(of: UInt32(number), parent: UInt32(directory), size: Int(blockSize))
                )
            }
            let type = superblock.incompat & 0x0002 != 0 ? Self.typeCode(kind) : 0
            let placed = try place(name, inode: number, type: type, in: parent, allocation: &allocation)
            if let (block, bytes) = firstBlock { try device.write(at: block * blockSize, bytes) }
            if placed.grown, let (block, bytes) = placed.block { try device.write(at: block * blockSize, bytes) }
            try writeAllocation(allocation, on: device)
            try device.flush()
            // Phase two: the name (in a block with room, or the block the parent grows by, linked). A crash after it leaves a
            // name for an inode not yet written, which preen clears; an unconnected directory it would not reconnect.
            if !placed.grown, let (block, bytes) = placed.block { try device.write(at: block * blockSize, bytes) }
            for (block, content) in allocation.changedIndirectBlocks {
                try device.write(at: block * blockSize, content)
            }
            let grownSectors = UInt64(allocation.allocated.count - (kind == .directory ? 1 : 0)) * blockSize / 512
            try touch(parent, on: device) { raw in
                guard placed.grown else { return }
                for (index, pointer) in allocation.pointers.enumerated() {
                    Self.put32(pointer, at: 0x28 + index * 4, in: &raw)
                }
                Self.put32(UInt32(parent.size + blockSize), at: 0x04, in: &raw)
                Self.put32(UInt32(parent.sectors + grownSectors), at: 0x1C, in: &raw)
            }
            try device.flush()
            // Phase three: the inode, and the parent's link to a new directory.
            try writeNewInode(number, kind: kind, mode: mode, owner: owner, pointers: own, on: device)
            if kind == .directory {
                // `touch` reads the inode's bytes from the device: phase two's pointers and size stay.
                try touch(parent, on: device) { raw in
                    Self.put16(parent.linkCount + 1, at: 0x1A, in: &raw)
                }
            }
            forget(allocation, directory: directory, block: placed.block?.0)
            free = allocation.free
            return number
        }
    }

    public func remove(_ name: [UInt8], from directory: UInt64) throws(DiskError) {
        let device = try openDevice()
        try Self.validate(name)
        let parent = try changeableDirectory(directory)
        let entry = try lookup(name, in: directory)
        let target = try inode(entry.id)
        let isDirectory = target.kind == .directory
        if isDirectory, !(try listing(entry.id).isEmpty) { throw .notEmpty }
        guard target.xattrBlock == 0 else { throw .unsupported("removing a node with an extended-attribute block") }
        try freeCounts.withLock { (free) throws(DiskError) in
            var allocation = try allocation(for: parent, on: device, free: free ?? initialFreeCounts)
            let blockSize = UInt64(superblock.blockSize)
            // Phase one: the node loses this name, and goes once it has none.
            let links = isDirectory ? 0 : target.linkCount - 1
            if links == 0 {
                for block in try blocksOwned(by: target) { try allocation.free(block: block) }
                try allocation.free(inode: target.number, directory: isDirectory)
            }
            let now = clock()
            try touch(target, on: device) { raw in
                Self.put16(links, at: 0x1A, in: &raw)
                if links == 0 { Self.put32(UInt32(truncatingIfNeeded: now.seconds), at: 0x14, in: &raw) }
            }
            try writeAllocation(allocation, on: device)
            try device.flush()
            // Phase two: the name.
            var removed: (UInt64, [UInt8])?
            for (_, physical) in try directoryBlocks(parent) {
                let bytes = try device.read(at: physical * blockSize, count: Int(blockSize))
                if let changed = try ExtDirectoryEntries.removing(name, from: bytes) {
                    removed = (physical, changed)
                    break
                }
            }
            guard let (block, bytes) = removed else { throw .corrupt("\(directory): the name found is in no block") }
            try device.write(at: block * blockSize, bytes)
            try touch(parent, on: device) { raw in
                if isDirectory { Self.put16(parent.linkCount - 1, at: 0x1A, in: &raw) }
            }
            forget(allocation, directory: directory, block: block)
            listings.invalidate(entry.id)
            mappings.invalidate(entry.id)
            free = allocation.free
        }
    }

    // MARK: Pieces

    /// A name a directory can hold: 1 to 255 bytes, neither `.` nor `..`, without a slash or a NUL.
    static func validate(_ name: [UInt8]) throws(DiskError) {
        guard name.count <= 255 else { throw .nameTooLong }
        guard !name.isEmpty, name != [0x2E], name != [0x2E, 0x2E], !name.contains(0x2F), !name.contains(0) else {
            throw .invalidName
        }
    }

    /// The directory `id`, if this writer can change its names: linear, stored in blocks.
    private func changeableDirectory(_ id: UInt64) throws(DiskError) -> ExtInode {
        let directory = try inode(id)
        guard directory.kind == .directory else { throw .notDirectory }
        guard directory.flags & ExtInode.indexFlag == 0 else {
            throw .unsupported("changing an indexed directory (a later slice)")
        }
        guard directory.flags & (ExtInode.inlineDataFlag | ExtInode.extentsFlag) == 0 else {
            throw .unsupported("changing an inline or extent-mapped directory (a later slice)")
        }
        guard superblock.clusterSize == superblock.blockSize, !superblock.hasGroupDescriptorChecksums else {
            throw .unsupported("allocating on a volume with clusters or descriptor checksums (a later slice)")
        }
        return directory
    }

    func allocation(
        for directory: ExtInode,
        on device: any WritableBlockSource,
        free: ExtFreeCounts
    ) throws(DiskError) -> ExtAllocation {
        let runs = try runs(directory)
        return ExtAllocation(
            superblock: superblock,
            device: device,
            free: free,
            pointers: try (0 ..< 15)
                .map { (index) throws(DiskError) -> UInt32 in try directory.blockArea.u32(index * 4) },
            goal: runs.compactMap { run in run.physical.map { $0 + run.count } }.max() ?? 0
        )
    }

    /// The directory's stored blocks, as (logical, physical).
    private func directoryBlocks(_ directory: ExtInode) throws(DiskError) -> [(UInt64, UInt64)] {
        try runs(directory)
            .flatMap { run -> [(UInt64, UInt64)] in
                guard let physical = run.physical else { return [] }
                return (0 ..< run.count).map { (run.logical + $0, physical + $0) }
            }
    }

    /// Where the entry goes: an existing block with room, or a new one the directory grows by (allocated and linked through
    /// `allocation`).
    private func place(
        _ name: [UInt8],
        inode number: UInt64,
        type: UInt8,
        in directory: ExtInode,
        allocation: inout ExtAllocation
    ) throws(DiskError) -> (block: (UInt64, [UInt8])?, grown: Bool) {
        let blockSize = UInt64(superblock.blockSize)
        for (_, physical) in try directoryBlocks(directory) {
            let bytes = try device?.read(at: physical * blockSize, count: Int(blockSize)) ?? []
            if let changed = try ExtDirectoryEntries.inserting(name, inode: UInt32(number), type: type, into: bytes) {
                return ((physical, changed), false)
            }
        }
        let block = try allocation.allocate()
        try allocation.link(directory.size / blockSize, to: block)
        let empty = ExtDirectoryEntries.emptyBlock(size: Int(blockSize))
        guard let bytes = try ExtDirectoryEntries.inserting(name, inode: UInt32(number), type: type, into: empty) else {
            throw .corrupt("a name that does not fit in an empty block")
        }
        return ((block, bytes), true)
    }

    /// The bitmaps and descriptors an allocation changed, and the new indirect blocks: phase one's metadata.
    func writeAllocation(_ allocation: ExtAllocation, on device: any WritableBlockSource) throws(DiskError) {
        let blockSize = UInt64(superblock.blockSize)
        for (block, content) in allocation.metadata.sorted(by: { $0.key < $1.key }) {
            try device.write(at: block * blockSize, content)
        }
        for (block, content) in allocation.newIndirectBlocks { try device.write(at: block * blockSize, content) }
    }

    /// The caches a name change made stale.
    private func forget(_ allocation: ExtAllocation, directory: UInt64, block: UInt64?) {
        for changed in allocation.metadata.keys { blocks.invalidate(changed) }
        for changed in allocation.indirect.keys { blocks.invalidate(changed) }
        if let block { blocks.invalidate(block) }
        listings.invalidate(directory)
        mappings.invalidate(directory)
    }

    /// The directory entry's file type byte (`filetype`): 1 a file, 2 a directory, 7 a symbolic link.
    static func typeCode(_ kind: NodeKind) -> UInt8 {
        switch kind {
            case .directory: 2
            case .symlink: 7
            default: 1
        }
    }
}
