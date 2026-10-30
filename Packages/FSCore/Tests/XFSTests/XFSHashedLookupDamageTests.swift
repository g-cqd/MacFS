import FSCore
import Testing

@testable import XFS

/// Hashed lookup over damaged directories (roadmap 0037): one block changed at a time, its checksum recomputed unless the
/// checksum is under test, so only the check under test can catch it, as the kernel's verifiers would
/// (`xfs_da3_node_verify`, `xfs_dir3_leaf_check_int`, `__xfs_dir3_data_check`).
@Suite struct XFSHashedLookupDamageTests {
    /// A directory of an image with some of its directory blocks changed.
    struct Damaged {
        let source: any BlockSource
        let fileSystem: XFSFileSystem
        let inode: XFSInode
        private(set) var blocks: [UInt64: [UInt8]] = [:]

        init(_ image: String, _ path: String) throws {
            source = try ImageOracle.image(image)
            fileSystem = try XFSFileSystem(source: source)
            inode = try fileSystem.inode(try XFSImageTests.path(fileSystem, path))
        }

        var dirBlockSize: Int { fileSystem.superblock.dirBlockSize }

        /// The directory block at a logical byte offset, as changed so far.
        func block(at logical: UInt64) throws -> DiskBytes {
            if let changed = blocks[logical] { return DiskBytes(changed) }
            return DiskBytes(try fileSystem.mapped(inode, at: logical, count: dirBlockSize))
        }

        /// Where a node's entry `index` leads, as a logical byte offset.
        func child(of logical: UInt64, _ index: Int) throws -> UInt64 {
            UInt64(try block(at: logical).be32(64 + 8 * index + 4)) * UInt64(fileSystem.superblock.blockSize)
        }

        /// Changes the block at `logical`, its checksum (at 12 in da blocks, at 4 in data blocks) recomputed if asked.
        mutating func change(at logical: UInt64, recompute: Bool = true, _ edit: (inout [UInt8]) -> Void) throws {
            var raw = try block(at: logical).array
            edit(&raw)
            if recompute {
                let field = logical >= XFSDirectory.leafOffset ? 12 : 4
                let crc = try XFSChecksum.compute(DiskBytes(raw), at: field)
                for index in 0 ..< 4 { raw[field + index] = UInt8(truncatingIfNeeded: crc >> (8 * index)) }
            }
            blocks[logical] = raw
        }

        /// The image with the changes, and the directory in it.
        func patched() throws -> (XFSFileSystem, XFSInode) {
            let blockSize = UInt64(fileSystem.superblock.blockSize)
            let extents = try fileSystem.extents(inode)
            var patches: [UInt64: UInt8] = [:]
            for (logical, raw) in blocks {
                for piece in 0 ..< UInt64(dirBlockSize) / blockSize {
                    let fileBlock = logical / blockSize + piece
                    let extent = try #require(extents.first { $0.logical <= fileBlock && fileBlock < $0.end })
                    let at = (extent.physical + fileBlock - extent.logical) * blockSize
                    for index in 0 ..< Int(blockSize) {
                        patches[at + UInt64(index)] = raw[Int(piece * blockSize) + index]
                    }
                }
            }
            let patched = try XFSFileSystem(source: PatchedSource(base: source, patches: patches))
            return (patched, try patched.inode(inode.number))
        }

        /// The name of the data entry at `address` (its byte offset in the directory over 8), as changed so far.
        func name(at address: UInt32) throws -> [UInt8] {
            let offset = UInt64(address) << 3
            let size = UInt64(dirBlockSize)
            let block = try block(at: offset - offset % size)
            let at = Int(offset % size)
            return try block.bytes(at + 9, Int(try block.u8(at + 8)))
        }
    }

    static let root = XFSDirectory.leafOffset
    static let collideName = Array("0001csss".utf8)

    static func put16(_ raw: inout [UInt8], _ at: Int, _ value: UInt16) {
        for index in 0 ..< 2 { raw[at + index] = UInt8(truncatingIfNeeded: value >> (8 - 8 * index)) }
    }

    static func put32(_ raw: inout [UInt8], _ at: Int, _ value: UInt32) {
        for index in 0 ..< 4 { raw[at + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * index)) }
    }

    /// The error a lookup of `name` throws, or nil.
    static func error(_ fileSystem: XFSFileSystem, _ inode: XFSInode, _ name: [UInt8]) -> DiskError? {
        do {
            _ = try fileSystem.hashedLookup(name, in: inode)
            return nil
        } catch { return error }
    }

    enum Block { case node, leaf }

    /// collide/ of xfs-hash, and the offset of its node or of the node's first leaf.
    static func collide(_ which: Block) throws -> (Damaged, UInt64) {
        let damaged = try Damaged("xfs-hash", "collide")
        return (damaged, which == .node ? root : try damaged.child(of: root, 0))
    }

    /// One changed byte in collide/'s node or its first leaf, the checksum left as it was.
    @Test(arguments: [Block.node, .leaf])
    func aChangedDaBlockIsAChecksumError(_ which: Block) throws {
        var (damaged, logical) = try Self.collide(which)
        try damaged.change(at: logical, recompute: false) { $0[70] ^= 1 }
        let (fileSystem, inode) = try damaged.patched()
        XFSChecksumTests.expectChecksumError(
            { _ = try fileSystem.hashedLookup(Self.collideName, in: inode) }, "\(which)")
    }

    /// Another directory's block (owner at 48) or a block of another kind (magic at 8), its checksum right.
    @Test(arguments: [(Block.node, 55), (.node, 9), (.leaf, 55), (.leaf, 9)])
    func aDaBlockOfAnotherOwnerOrKindIsCorrupt(_ which: Block, _ byte: Int) throws {
        var (damaged, logical) = try Self.collide(which)
        try damaged.change(at: logical) { $0[byte] ^= 1 }
        let (fileSystem, inode) = try damaged.patched()
        guard case .corrupt = Self.error(fileSystem, inode, Self.collideName) else {
            Issue.record(
                "\(which), byte \(byte): \(String(describing: Self.error(fileSystem, inode, Self.collideName)))")
            return
        }
    }

    /// A LEAF1 block's entries may reach its bests table, not overlap it (xfs_dir3_leaf_check_int): the bests count
    /// set so the two meet, then one more.
    @Test func aLeafsEntriesMeetItsBestsAndNoMore() throws {
        var damaged = try Damaged("xfs-hash", "leaf")
        let size = damaged.dirBlockSize
        let count = Int(try damaged.block(at: Self.root).be16(56))
        let bests = (size - 4 - 64 - 8 * count) / 2
        let names = try damaged.fileSystem.listing(damaged.inode.number).entries
        try damaged.change(at: Self.root) { Self.put32(&$0, size - 4, UInt32(bests)) }
        var (fileSystem, inode) = try damaged.patched()
        for entry in names { #expect(try fileSystem.hashedLookup(entry.name, in: inode)?.inode == entry.inode) }
        try damaged.change(at: Self.root) { Self.put32(&$0, size - 4, UInt32(bests + 1)) }
        (fileSystem, inode) = try damaged.patched()
        #expect(
            Self.error(fileSystem, inode, names[0].name)
                == .corrupt("directory \(inode.number): a leaf of \(count) entries and \(bests + 1) bests"))
    }

    /// A da block's entries may fill it, and no more (the node's and the leaf's most entries): the root of xfs-hash-1k's
    /// deep/ given that many entries, then one more.
    @Test func aDaBlocksEntriesFillItAndNoMore() throws {
        var damaged = try Damaged("xfs-hash-1k", "deep")
        let most = (damaged.dirBlockSize - 64) / 8
        let name = Array("n1".utf8)
        try damaged.change(at: Self.root) { Self.put16(&$0, 56, UInt16(most + 1)) }
        var (fileSystem, inode) = try damaged.patched()
        let tooMany = DiskError.corrupt("directory \(inode.number): a da block of \(most + 1) entries")
        #expect(Self.error(fileSystem, inode, name) == tooMany)
        try damaged.change(at: Self.root) { Self.put16(&$0, 56, UInt16(most)) }
        (fileSystem, inode) = try damaged.patched()
        let full = DiskError.corrupt("directory \(inode.number): a da block of \(most) entries")
        #expect(Self.error(fileSystem, inode, name) != full)
    }

    /// A node's level is 1 to 5 (XFS_DA_NODE_MAXDEPTH) and one above its children's, and a node has entries: collide/'s
    /// root (level 1, over leaves) given other levels, and no entries.
    @Test func aNodesLevelAndCountAreChecked() throws {
        let base = try Damaged("xfs-hash", "collide")
        let count = Int(try base.block(at: Self.root).be16(56))
        let number = base.inode.number
        for (level, entries, message) in [
            (0, count, "a node of level 0 and \(count) entries"), (6, count, "a node of level 6 and \(count) entries"),
            (5, count, "a leaf where a node of level 4 was"), (2, count, "a leaf where a node of level 1 was"),
            (1, 0, "a node of level 1 and 0 entries")
        ] {
            var damaged = base
            try damaged.change(at: Self.root) {
                Self.put16(&$0, 58, UInt16(level))
                Self.put16(&$0, 56, UInt16(entries))
            }
            let (fileSystem, inode) = try damaged.patched()
            #expect(Self.error(fileSystem, inode, Self.collideName) == .corrupt("directory \(number): \(message)"))
        }
    }

    enum Root { case nodeOfOneEntry, leaf }

    /// The tree reduced to collide/'s first leaf: a root node of one entry, or that leaf at the root (`LEAFN` at the leaf
    /// offset, as `xfs_da3_root_join` leaves a shrunk directory). The leaf's names (but "." and "..", which its hashes
    /// hold too) are found, the others are not: the run of their hash goes on, but nothing comes after.
    @Test(arguments: [Root.nodeOfOneEntry, .leaf])
    func aTreeOfOneLeafHoldsThatLeafsNames(_ root: Root) throws {
        var damaged = try Damaged("xfs-hash", "collide")
        let first = try damaged.block(at: try damaged.child(of: Self.root, 0))
        var held = 0
        for index in 0 ..< Int(try first.be16(56)) {
            let address = try first.be32(68 + 8 * index)
            guard address != 0, ![[0x2E], [0x2E, 0x2E]].contains(try damaged.name(at: address)) else { continue }
            held += 1
        }
        switch root {
            case .nodeOfOneEntry: try damaged.change(at: Self.root) { Self.put16(&$0, 56, 1) }
            case .leaf: try damaged.change(at: Self.root) { $0 = first.array }
        }
        let names = try damaged.fileSystem.listing(damaged.inode.number).entries
        let (fileSystem, inode) = try damaged.patched()
        var found = 0
        for entry in names {
            guard let hit = try fileSystem.hashedLookup(entry.name, in: inode) else { continue }
            #expect(hit.inode == entry.inode)
            found += 1
        }
        #expect(held > 0 && found == held, "\(found) of \(held)")
    }

    /// A run of one hash across two leaves under different level-1 nodes of deep/'s level-2 tree: the lookup climbs to
    /// the root and down the next node (`xfs_da3_path_shift` at two levels). The image has none, so one is made: the last
    /// hash of the root's first subtree (its root entry, its node entry, its last leaf entry) set to the first hash of the
    /// second subtree, whose name the lookup must then reach.
    @Test func aRunGoesOnAcrossNodes() throws {
        var damaged = try Damaged("xfs-hash", "deep")
        try #require(try damaged.block(at: Self.root).be16(58) == 2)
        let (left, right) = (try damaged.child(of: Self.root, 0), try damaged.child(of: Self.root, 1))
        let leftCount = Int(try damaged.block(at: left).be16(56))
        let lastLeaf = try damaged.child(of: left, leftCount - 1)
        let lastCount = Int(try damaged.block(at: lastLeaf).be16(56))
        let firstLeaf = try damaged.block(at: try damaged.child(of: right, 0))
        let index = try #require(
            try (0 ..< Int(try firstLeaf.be16(56))).first { (index) throws in try firstLeaf.be32(68 + 8 * index) != 0 })
        let hash = try firstLeaf.be32(64 + 8 * index)
        let name = try damaged.name(at: try firstLeaf.be32(68 + 8 * index))
        #expect(XFSDirectoryHash.hash(name) == hash)
        try damaged.change(at: Self.root) { Self.put32(&$0, 64, hash) }
        try damaged.change(at: left) { Self.put32(&$0, 64 + 8 * (leftCount - 1), hash) }
        try damaged.change(at: lastLeaf) { Self.put32(&$0, 64 + 8 * (lastCount - 1), hash) }
        let (fileSystem, inode) = try damaged.patched()
        #expect(try fileSystem.hashedLookup(name, in: inode)?.name == name)
    }

    /// Names of hashes outside a node tree's: below every one, and above every one (each level's last entry taken).
    @Test(arguments: XFSHashedLookupTests.images)
    func hashesOutsideTheTreeAreNotFound(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        for path in ["collide", "deep"] {
            let inode = try fileSystem.inode(try XFSImageTests.path(fileSystem, path))
            let root = DiskBytes(
                try fileSystem.mapped(inode, at: Self.root, count: fileSystem.superblock.dirBlockSize))
            let (low, high) = (try root.be32(64), try root.be32(64 + 8 * (Int(try root.be16(56)) - 1)))
            var outside: (below: [UInt8]?, above: [UInt8]?) = (nil, nil)
            for index in 0 ..< 10_000_000 where outside.below == nil || outside.above == nil {
                let name = Array("absent-\(index)".utf8)
                let hash = XFSDirectoryHash.hash(name)
                if hash < low && outside.below == nil { outside.below = name }
                if hash > high && outside.above == nil { outside.above = name }
            }
            for name in [outside.below, outside.above] {
                let name = try #require(name, "\(path)")
                #expect(try fileSystem.hashedLookup(name, in: inode) == nil, "\(path)")
            }
        }
    }

    enum EntryDamage { case freeTag, noLength, pastTheEnd, toTheEnd }

    /// A leaf entry addresses a data entry: in use (not the free tag 0xFFFF), named, and inside its block. leaf/'s last
    /// entry of its first data block changed: free, of no length, one byte past the block's end; or reaching it exactly,
    /// which is in bounds.
    @Test(arguments: [EntryDamage.freeTag, .noLength, .pastTheEnd, .toTheEnd])
    func aLeafEntryAddressesADataEntryInItsBlock(_ damage: EntryDamage) throws {
        var damaged = try Damaged("xfs-hash", "leaf")
        let size = damaged.dirBlockSize
        let block = try damaged.block(at: 0)
        var (at, last) = (64, 64)
        while at < size {
            if try block.be16(at) == 0xFFFF {
                at += Int(try block.be16(at + 2))
                continue
            }
            last = at
            at += (12 + Int(try block.u8(at + 8)) + 7) & ~7
        }
        let name = try block.bytes(last + 9, Int(try block.u8(last + 8)))
        try #require(size - last - 12 <= 254)
        try damaged.change(at: 0) {
            switch damage {
                case .freeTag: Self.put16(&$0, last, 0xFFFF)
                case .noLength: $0[last + 8] = 0
                case .pastTheEnd: $0[last + 8] = UInt8(size + 1 - last - 12)
                case .toTheEnd: $0[last + 8] = UInt8(size - last - 12)
            }
        }
        let (fileSystem, inode) = try damaged.patched()
        let error = Self.error(fileSystem, inode, name)
        let outside = DiskError.corrupt("directory \(inode.number): a leaf entry addressing no data entry")
        #expect(error == (damage == .toTheEnd ? nil : outside), "\(damage)")
    }

    /// A block directory's entries end where its leaf begins: before `count` leaf entries and the tail (count, stale);
    /// a data block's at its end.
    @Test func aBlockDirectorysEntriesEndAtItsLeaf() throws {
        var raw = [UInt8](repeating: 0, count: 4_096)
        Self.put32(&raw, 0, XFSDirectory.blockMagic)
        Self.put32(&raw, 4_088, 3)
        #expect(try XFSDirectory.entriesEnd(DiskBytes(raw), directory: 1) == 4_096 - 8 - 3 * 8)
        // The most leaf entries leave the 64-byte header, and no more.
        Self.put32(&raw, 4_088, 503)
        #expect(try XFSDirectory.entriesEnd(DiskBytes(raw), directory: 1) == 64)
        Self.put32(&raw, 4_088, 504)
        #expect(throws: DiskError.corrupt("directory 1: a leaf of 56 bytes")) {
            try XFSDirectory.entriesEnd(DiskBytes(raw), directory: 1)
        }
        Self.put32(&raw, 0, 0x5844_4433)
        #expect(try XFSDirectory.entriesEnd(DiskBytes(raw), directory: 1) == 4_096)
    }
}
