public import FSCore
import Synchronization

/// ext2 rename and hard links (roadmap 0026 step 3), in the orders e2fsck's preen repairs: a rename within one block is one
/// write; otherwise a node replaced by it is given up first, then the name points to the moved node, then the old name goes (a
/// crash between leaves two names for one link, which preen counts again); a hard link raises the link count, then adds the
/// name. A directory moved to another block or parent has no such order without a journal: a crash may leave it with two
/// names, or its `..` behind, which only `e2fsck -fy` repairs (ADR-0018, as Linux's ext2).
extension ExtFileSystem {
    public func rename(
        _ name: [UInt8],
        in directory: UInt64,
        to newName: [UInt8],
        in newDirectory: UInt64
    ) throws(DiskError) {
        let device = try openDevice()
        try Self.validate(name)
        try Self.validate(newName)
        let source = try changeableDirectory(directory)
        let target = newDirectory == directory ? source : try changeableDirectory(newDirectory)
        let moving = try inode(try lookup(name, in: directory).id)
        let existing = try? lookup(newName, in: newDirectory)
        // Onto itself, or onto another name of the same node: nothing to do (POSIX).
        if existing?.id == moving.number { return }
        let replaced = try existing.map { (entry) throws(DiskError) -> ExtInode in try replaceable(entry, by: moving) }
        if moving.kind == .directory, newDirectory != directory { try requireOutside(moving.number, newDirectory) }
        if newDirectory == directory, replaced == nil,
            try renameInOneBlock(name, to: newName, moving: moving, in: source, on: device)
        {
            return
        }
        let move = Move(
            name: name,
            newName: newName,
            moving: moving,
            source: source,
            target: target,
            replaced: replaced
        )
        try renameInPhases(move, on: device)
    }

    /// What a phased rename changes.
    private struct Move {
        let name: [UInt8]
        let newName: [UInt8]
        let moving: ExtInode
        let source: ExtInode
        let target: ExtInode
        let replaced: ExtInode?
        var moves: Bool { moving.kind == .directory && target.number != source.number }
    }

    /// The node with the new name, if POSIX lets the rename replace it: a file by a file, an empty directory by a directory.
    private func replaceable(_ entry: DirectoryEntry, by moving: ExtInode) throws(DiskError) -> ExtInode {
        let node = try inode(entry.id)
        let isDirectory = moving.kind == .directory
        if node.kind == .directory, !isDirectory { throw .isDirectory }
        if node.kind != .directory, isDirectory { throw .notDirectory }
        if node.kind == .directory, !(try listing(node.number).isEmpty) { throw .notEmpty }
        guard node.xattrBlock == 0 else { throw .unsupported("replacing a node with an extended-attribute block") }
        return node
    }

    /// Within one directory, when the old name's block has room for the new one: both in one write, no window at all.
    private func renameInOneBlock(
        _ name: [UInt8],
        to newName: [UInt8],
        moving: ExtInode,
        in directory: ExtInode,
        on device: any WritableBlockSource
    ) throws(DiskError) -> Bool {
        let type = superblock.incompat & 0x0002 != 0 ? Self.typeCode(moving.kind) : 0
        guard
            let block = try? rewrite(
                directory,
                on: device,
                { (bytes) throws(DiskError) -> [UInt8]? in
                    guard let without = try ExtDirectoryEntries.removing(name, from: bytes) else { return nil }
                    return try ExtDirectoryEntries.inserting(
                        newName,
                        inode: UInt32(moving.number),
                        type: type,
                        into: without
                    )
                }
            )
        else { return false }
        try touch(moving, on: device)
        blocks.invalidate(block)
        listings.invalidate(directory.number)
        return true
    }

    private func renameInPhases(_ move: Move, on device: any WritableBlockSource) throws(DiskError) {
        try freeCounts.withLock { (free) throws(DiskError) in
            var allocation = try allocation(for: move.target, on: device, free: free ?? initialFreeCounts)
            var changed: [UInt64] = []
            if let replaced = move.replaced {
                // The replaced node gives up this name first: a crash leaves the name for a deleted node, which preen clears.
                try giveUp(replaced, allocation: &allocation, on: device)
                try writeAllocation(allocation, on: device)
                try device.flush()
                let type = superblock.incompat & 0x0002 != 0 ? Self.typeCode(move.moving.kind) : 0
                changed.append(
                    try rewrite(move.target, on: device) { (bytes) throws(DiskError) in
                        try ExtDirectoryEntries.retargeting(
                            move.newName,
                            to: UInt32(move.moving.number),
                            type: type,
                            in: bytes
                        )
                    }
                )
                if replaced.kind == .directory { try setLinks(move.target, by: -1, on: device) }
            } else if let block = try addName(
                move.newName,
                inode: move.moving.number,
                kind: move.moving.kind,
                in: move.target,
                allocation: &allocation,
                on: device
            ) {
                changed.append(block)
            }
            if move.moves { try setLinks(move.target, by: 1, on: device) }
            try device.flush()
            // The old name, and a moved directory's `..`.
            changed.append(
                try rewrite(move.source, on: device) { (bytes) throws(DiskError) in
                    try ExtDirectoryEntries.removing(move.name, from: bytes)
                }
            )
            if move.moves {
                changed.append(
                    try rewrite(move.moving, on: device) { (bytes) throws(DiskError) in
                        try ExtDirectoryEntries.retargeting(
                            [0x2E, 0x2E],
                            to: UInt32(move.target.number),
                            type: 2,
                            in: bytes
                        )
                    }
                )
                try setLinks(move.source, by: -1, on: device)
            }
            try touch(move.moving, on: device)
            for block in changed { blocks.invalidate(block) }
            forget(allocation, directory: move.target.number, block: nil)
            listings.invalidate(move.source.number)
            listings.invalidate(move.moving.number)
            if let replaced = move.replaced {
                listings.invalidate(replaced.number)
                mappings.invalidate(replaced.number)
            }
            free = allocation.free
        }
    }

    public func link(_ id: UInt64, as name: [UInt8], in directory: UInt64) throws(DiskError) {
        let device = try openDevice()
        try Self.validate(name)
        let parent = try changeableDirectory(directory)
        let node = try inode(id)
        guard node.kind != .directory else { throw .isDirectory }
        if (try? lookup(name, in: directory)) != nil { throw .exists }
        guard node.linkCount < 32_000 else { throw .unsupported("a node with 32000 links") }
        try freeCounts.withLock { (free) throws(DiskError) in
            var allocation = try allocation(for: parent, on: device, free: free ?? initialFreeCounts)
            // The count first: a crash before the name leaves one too many, which preen counts again.
            try setLinks(node, by: 1, on: device)
            try device.flush()
            let block = try addName(name, inode: id, kind: node.kind, in: parent, allocation: &allocation, on: device)
            forget(allocation, directory: directory, block: block)
            free = allocation.free
        }
    }

    // MARK: Pieces

    /// A node losing one name: its link count lowered, and once it has none (a directory always), its blocks and inode freed
    /// and its deletion time set.
    func giveUp(_ node: ExtInode, allocation: inout ExtAllocation, on device: any WritableBlockSource) throws(DiskError)
    {
        let isDirectory = node.kind == .directory
        let links = isDirectory ? 0 : node.linkCount - 1
        if links == 0 {
            for block in try blocksOwned(by: node) { try allocation.free(block: block) }
            try allocation.free(inode: node.number, directory: isDirectory)
        }
        let now = clock()
        try touch(node, on: device) { raw in
            Self.put16(links, at: 0x1A, in: &raw)
            if links == 0 { Self.put32(UInt32(truncatingIfNeeded: now.seconds), at: 0x14, in: &raw) }
        }
    }

    /// The directory's link count moved by `change`, its times with it (read from the device: an earlier change in this
    /// operation may have rewritten the inode).
    private func setLinks(_ node: ExtInode, by change: Int, on device: any WritableBlockSource) throws(DiskError) {
        let location = try inodeLocation(node.number)
        let at = location.block * UInt64(superblock.blockSize) + UInt64(location.offset)
        let links = try DiskBytes(try device.read(at: at, count: superblock.inodeSize)).u16(0x1A)
        try touch(node, on: device) { raw in Self.put16(UInt16(Int(links) + change), at: 0x1A, in: &raw) }
    }

    /// The first of `directory`'s blocks `edit` changes, written; its number. `edit` answers nil for a block without the name.
    private func rewrite(
        _ directory: ExtInode,
        on device: any WritableBlockSource,
        _ edit: ([UInt8]) throws(DiskError) -> [UInt8]?
    ) throws(DiskError) -> UInt64 {
        let blockSize = UInt64(superblock.blockSize)
        for (_, physical) in try directoryBlocks(directory) {
            let bytes = try device.read(at: physical * blockSize, count: Int(blockSize))
            if let changed = try edit(bytes) {
                try device.write(at: physical * blockSize, changed)
                try touch(directory, on: device)
                return physical
            }
        }
        throw .corrupt("directory \(directory.number): the name found is in no block")
    }

    /// Refuses moving directory `moving` into `destination` when that is `moving` itself or below it: walking up from the
    /// destination must reach the root without meeting it.
    private func requireOutside(_ moving: UInt64, _ destination: UInt64) throws(DiskError) {
        var current = destination
        var steps = 0
        while current != rootID {
            if current == moving { throw .invalidName }
            current = try attributes(of: current).parent
            steps += 1
            guard steps < 1 << 16 else { throw .corrupt("a directory loop above \(destination)") }
        }
        if moving == rootID { throw .invalidName }
    }
}
