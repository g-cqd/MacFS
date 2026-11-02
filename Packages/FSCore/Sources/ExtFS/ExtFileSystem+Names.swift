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
        try serialized { () throws(DiskError) -> UInt64 in
            guard kind == .regular || kind == .directory else {
                throw .unsupported("creating a \(kind) (a later slice)")
            }
            return try makeNode(name, kind: kind, in: directory, mode: mode, owner: owner, target: [])
        }
    }

    public func createSymlink(
        _ name: [UInt8],
        target: [UInt8],
        in directory: UInt64,
        owner: (uid: UInt32, gid: UInt32)
    ) throws(DiskError) -> UInt64 {
        try serialized { () throws(DiskError) -> UInt64 in
            guard !target.isEmpty, !target.contains(0) else { throw .invalidName }
            guard target.count < superblock.blockSize else { throw .nameTooLong }
            return try makeNode(name, kind: .symlink, in: directory, mode: 0o777, owner: owner, target: target)
        }
    }

    /// A file, a directory or a symbolic link (to `target`) made and named.
    private func makeNode(
        _ name: [UInt8],
        kind: NodeKind,
        in directory: UInt64,
        mode: UInt16,
        owner: (uid: UInt32, gid: UInt32),
        target: [UInt8]
    ) throws(DiskError) -> UInt64 {
        let device = try openDevice()
        try Self.validate(name)
        let parent = try changeableDirectory(directory)
        if (try? lookup(name, in: directory)) != nil { throw .exists }
        if kind == .directory, parent.linkCount >= 32_000 { throw .unsupported("a directory with 32000 links") }
        return try freeCounts.withLock { (free) throws(DiskError) -> UInt64 in
            var allocation = try allocation(for: parent, on: device, free: free ?? initialFreeCounts)
            let group = (directory - 1) / UInt64(superblock.inodesPerGroup)
            let number = try allocation.allocateInode(near: group, directory: kind == .directory)
            let blockSize = UInt64(superblock.blockSize)
            // Phase one: the blocks nothing points to yet (a directory's first block, a block the parent grows by) and the
            // bitmaps; flushed, then the inode, which points to them, flushed: an unattached inode is still checked.
            var content = NewContent()
            var firstBlock: (UInt64, [UInt8])?
            // Under 60 bytes a symlink's target lives in the inode (a fast symlink, as Linux makes it); longer, in a block.
            if kind == .symlink, target.count < 60 {
                content = NewContent(size: UInt64(target.count), blockArea: target)
            } else if kind == .directory || kind == .symlink {
                allocation.goal = superblock.firstDataBlock + group * UInt64(superblock.blocksPerGroup)
                let block = try allocation.allocate()
                var bytes = ExtDirectoryEntries.firstBlock(
                    of: UInt32(number),
                    parent: UInt32(directory),
                    size: Int(blockSize)
                )
                if kind == .symlink {
                    bytes = target + [UInt8](repeating: 0, count: Int(blockSize) - target.count)
                }
                firstBlock = (block, bytes)
                let size = kind == .directory ? blockSize : UInt64(target.count)
                content = .oneBlock(block, size: size, blockSize: Int(blockSize))
            }
            let placed = try addName(
                name,
                inode: number,
                kind: kind,
                in: parent,
                allocation: &allocation,
                writingFirst: firstBlock.map { [$0] } ?? [],
                on: device
            )
            // Phase three: the inode, and the parent's link to a new directory.
            try writeNewInode(number, kind: kind, mode: mode, owner: owner, content: content, on: device)
            if kind == .directory {
                // `touch` reads the inode's bytes from the device: phase two's pointers and size stay.
                try touch(parent, on: device) { raw in
                    Self.put16(parent.linkCount + 1, at: 0x1A, in: &raw)
                }
            }
            forget(allocation, directory: directory, block: placed)
            free = allocation.free
            return number
        }
    }

    public func remove(_ name: [UInt8], from directory: UInt64) throws(DiskError) {
        try changingName(name, in: directory) { (device, parent, allocation) throws(DiskError) in
            let entry = try lookup(name, in: directory)
            let target = try inode(entry.id)
            let isDirectory = target.kind == .directory
            if isDirectory, !(try listing(entry.id).isEmpty) { throw .notEmpty }
            guard target.xattrBlock == 0 else { throw .unsupported("removing a node with an extended-attribute block") }
            let blockSize = UInt64(superblock.blockSize)
            // Phase one: the node loses this name, and goes once it has none.
            try giveUp(target, allocation: &allocation, on: device)
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
            guard let (block, bytes) = removed else {
                throw .corrupt("\(directory): the name found is in no block")
            }
            try device.write(at: block * blockSize, bytes)
            try touch(parent, on: device) { raw in
                if isDirectory { Self.put16(parent.linkCount - 1, at: 0x1A, in: &raw) }
            }
            forget(allocation, directory: directory, block: block)
            listings.invalidate(entry.id)
            mappings.invalidate(entry.id)
        }
    }

    /// A change to a name in `directory`, alone: the device, the name checked, the directory, and an allocation over the free
    /// counts, which keep what it left once `body` returns.
    func changingName(
        _ name: [UInt8],
        in directory: UInt64,
        _ body: (any WritableBlockSource, ExtInode, inout ExtAllocation) throws(DiskError) -> Void
    ) throws(DiskError) {
        try serialized { () throws(DiskError) in
            let device = try openDevice()
            try Self.validate(name)
            let parent = try changeableDirectory(directory)
            try freeCounts.withLock { (free) throws(DiskError) in
                var allocation = try allocation(for: parent, on: device, free: free ?? initialFreeCounts)
                try body(device, parent, &allocation)
                free = allocation.free
            }
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
    func changeableDirectory(_ id: UInt64) throws(DiskError) -> ExtInode {
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

    /// The bitmaps and descriptors an allocation changed, and the new indirect blocks: phase one's metadata.
    func writeAllocation(_ allocation: ExtAllocation, on device: any WritableBlockSource) throws(DiskError) {
        let blockSize = UInt64(superblock.blockSize)
        for (block, content) in allocation.metadata.sorted(by: { $0.key < $1.key }) {
            try device.write(at: block * blockSize, content)
        }
        for (block, content) in allocation.newIndirectBlocks { try device.write(at: block * blockSize, content) }
    }

    /// The caches a name change made stale.
    func forget(_ allocation: ExtAllocation, directory: UInt64, block: UInt64?) {
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
