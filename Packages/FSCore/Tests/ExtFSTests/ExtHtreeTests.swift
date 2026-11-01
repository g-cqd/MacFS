import FSCore
import Foundation
import Synchronization
import Testing

@testable import ExtFS

/// Hashed lookup in ext's indexed directories (roadmap 0016), as Linux's `dx_probe` and `ext4fs_dirhash` do it.
@Suite struct ExtHtreeTests {
    /// Every line of TestImages/dxhash.txt: e2fsprogs' `debugfs dx_hash` over names of 1 to 70 bytes and non-ASCII names,
    /// hash versions 0 to 5 (legacy, half-MD4, TEA, signed then unsigned) and two seeds.
    @Test func everyDirectoryHashMatchesE2fsprogs() throws {
        let text = try String(
            contentsOf: ImageOracle.directory.appendingPathComponent("dxhash.txt"),
            encoding: .utf8
        )
        var checked = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            try #require(fields.count == 5, "\(line)")
            let version = try #require(UInt8(fields[0]))
            let seedBytes = Hex.bytes(fields[1].replacingOccurrences(of: "-", with: ""))
            let seed = (0 ..< 4)
                .map { word in
                    (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(seedBytes[4 * word + $1]) << (8 * $1) }
                }
            let name = Hex.bytes(fields[2])
            let expected = (
                try #require(UInt32(fields[3].dropFirst(2), radix: 16)),
                try #require(UInt32(fields[4].dropFirst(2), radix: 16))
            )
            let hash = ExtDirectoryHash.hash(name, version: version, seed: seed)
            #expect(
                hash?.major == expected.0 && hash?.minor == expected.1,
                "version \(version), \(fields[2]), seed \(fields[1])"
            )
            checked += 1
        }
        #expect(checked == 900)
    }

    /// The images must carry the hashes they are for, or matching them proves nothing.
    @Test func theImagesHashEveryWay() throws {
        for (image, version, flags) in [
            ("ext4", UInt8(1), UInt32(2)), ("ext3", 2, 2), ("ext4-uuid-seed", 0, 2), ("ext4-bigalloc", 1, 1),
            ("ext4-grown", 1, 2)
        ] {
            let fileSystem = try ExtFileSystem(source: try ImageOracle.image(image))
            let sub = try fileSystem.inode(try Self.path(fileSystem, "dir/sub"))
            #expect(sub.flags & ExtInode.indexFlag != 0, "\(image): dir/sub should be indexed")
            let root = try fileSystem.block(try #require(try fileSystem.runs(sub).first?.physical))
            #expect(try root.u8(0x1C) == version, "\(image): hash version")
            #expect(fileSystem.superblock.flags & 3 == flags, "\(image): signedness")
        }
        let grown = try ExtFileSystem(source: try ImageOracle.image("ext4-grown"))
        let many = try grown.inode(try Self.path(grown, "many"))
        let root = try grown.block(try #require(try grown.runs(many).first?.physical))
        #expect(try root.u8(0x1E) == 1, "many/ should have interior index nodes")
    }

    /// Every name of every indexed directory is found through the index, with its inode; names not there are not.
    @Test(arguments: ExtImageTests.images)
    func everyNameOfAnIndexedDirectoryIsFoundThroughItsIndex(_ image: String) throws {
        let fileSystem = try ExtFileSystem(source: try ImageOracle.image(image))
        var indexed = 0
        var pending = [fileSystem.rootID]
        while let directory = pending.popLast() {
            let entries = try fileSystem.entries(of: directory, from: 0, limit: 100_000)
            pending += entries.filter { $0.kind == .directory }.map(\.id)
            let inode = try fileSystem.inode(directory)
            guard inode.flags & ExtInode.indexFlag != 0 else { continue }
            indexed += 1
            for entry in entries {
                guard case .found(let found) = try fileSystem.indexedLookup(entry.name, in: inode) else {
                    Issue.record("\(image): \(String(decoding: entry.name, as: UTF8.self)) not found through the index")
                    continue
                }
                #expect(found.inode == entry.id)
            }
            for missing in ["f301.txt", "F1.txt", "é21.txt", "e\u{301}1.txt", "no such name"] {
                guard case .absent = try fileSystem.indexedLookup(Array(missing.utf8), in: inode) else {
                    Issue.record("\(image): \(missing) should be absent")
                    continue
                }
            }
        }
        if image != "ext2" { #expect(indexed >= 1, "\(image) should have an indexed directory") }
    }

    /// The index is what a lookup uses: a name in dir/sub costs a few blocks, not the directory's thirteen.
    @Test func aLookupReadsAFewBlocksNotTheDirectory() throws {
        let source = CountingSource(try ImageOracle.image("ext4"))
        let fileSystem = try ExtFileSystem(source: source)
        let sub = try Self.path(fileSystem, "dir/sub")
        _ = try fileSystem.inode(sub)
        let before = source.reads.load(ordering: .relaxed)
        let entry = try fileSystem.lookup(Array("f150.txt".utf8), in: sub)
        #expect(try fileSystem.read(entry.id, at: 0, count: 100) == Array("file 150\n".utf8))
        #expect(source.reads.load(ordering: .relaxed) - before <= 6)
        // A miss stops at the leaf its hash leads to: the leaves after it are read only for a hash continued into them.
        for index in 0 ..< 10 {
            let start = source.reads.load(ordering: .relaxed)
            #expect(throws: DiskError.notFound) { try fileSystem.lookup(Array("missing-\(index)".utf8), in: sub) }
            #expect(source.reads.load(ordering: .relaxed) - start <= 2, "missing-\(index)")
        }
        // Once the directory is listed, its listing answers: no block is read.
        _ = try fileSystem.entries(of: sub, from: 0, limit: 1000)
        let listed = source.reads.load(ordering: .relaxed)
        _ = try fileSystem.lookup(Array("f7.txt".utf8), in: sub)
        #expect(source.reads.load(ordering: .relaxed) == listed)
    }

    /// An index the kernel would call bad (`ERR_BAD_DX_DIR`) is not followed: the scan finds every name, as Linux falls back to
    /// a linear search. Each case changes one byte of ext3's dir/sub root (no metadata checksums, so the change reads).
    @Test(arguments: [
        ("SipHash, which needs casefolding and encryption", 0x1C, UInt8(6)),
        ("a stored unsigned version (only the superblock flag makes one)", 0x1C, 4),
        ("an info length other than 8", 0x1D, 12),
        ("two interior levels without largedir", 0x1E, 2),
        ("an unimplemented hash flag", 0x1F, 1),
        ("a limit the block size does not give", 0x20, 7)
    ])
    func anIndexTheKernelWouldNotFollowIsScanned(_ what: String, _ offset: Int, _ value: UInt8) throws {
        let image = try ImageOracle.image("ext3")
        let plain = try ExtFileSystem(source: image)
        let sub = try plain.inode(try Self.path(plain, "dir/sub"))
        let root = try #require(try plain.runs(sub).first?.physical)
        let patched = PatchedSource(
            base: image,
            patches: [root * UInt64(plain.superblock.blockSize) + UInt64(offset): value]
        )
        let fileSystem = try ExtFileSystem(source: patched)
        guard case .notIndexed = try fileSystem.indexedLookup(Array("f1.txt".utf8), in: sub) else {
            Issue.record("\(what): followed")
            return
        }
        #expect(try fileSystem.lookup(Array("f1.txt".utf8), in: sub.number).id != 0)
    }

    /// Without `dir_index` the inode flag means nothing (`is_dx`): the directory is scanned, its index blocks read as empty.
    @Test func withoutDirIndexTheFlagIsIgnored() throws {
        let image = try ImageOracle.image("ext3")
        let compat = try image.read(at: 1024 + 0x5C, count: 1)[0]
        let fileSystem = try ExtFileSystem(source: PatchedSource(base: image, patches: [1024 + 0x5C: compat & ~0x20]))
        let sub = try fileSystem.inode(try Self.path(fileSystem, "dir/sub"))
        guard case .notIndexed = try fileSystem.indexedLookup(Array("f1.txt".utf8), in: sub) else {
            Issue.record("followed an index the volume does not enable")
            return
        }
        #expect(try fileSystem.entries(of: sub.number, from: 0, limit: 1000).count == 320)
    }

    /// A hash split across two leaves: the splitter marks the second leaf's index entry with the hash and its low bit set,
    /// and a lookup that lands on the first leaf must go on to the second. Made by hand on ext3 (no checksums): the index
    /// entry of leaf 2 takes the lowest hash in that leaf, marked, so that name's lookup lands on leaf 1.
    @Test func aHashSplitAcrossLeavesIsFollowedIntoTheNext() throws {
        let image = try ImageOracle.image("ext3")
        let plain = try ExtFileSystem(source: image)
        let sub = try plain.inode(try Self.path(plain, "dir/sub"))
        let runs = try plain.runs(sub)
        let root = try plain.block(try #require(runs.first?.physical))
        #expect(try root.u8(0x1E) == 0 && root.u16(32 + 2) >= 3, "a one-level index with three leaves or more")
        let version = try root.u8(0x1C) + (plain.superblock.flags & 2 != 0 ? 3 : 0)
        let leaf2 = UInt64(try root.u32(32 + 16 + 4))
        var names: [ExtDirectoryBlock.Entry] = []
        try ExtDirectoryBlock.entries(try plain.directoryBlock(leaf2, of: sub, runs: runs), into: &names)
        let hashed = try names.map { entry in
            (
                entry,
                try #require(ExtDirectoryHash.hash(entry.name, version: version, seed: plain.superblock.hashSeed)).major
            )
        }
        let (lowest, hash) = try #require(hashed.min { $0.1 < $1.1 })
        #expect(hashed.filter { $0.1 == hash }.count == 1)
        let marked = hash | 1
        let at = try #require(runs.first?.physical) * UInt64(plain.superblock.blockSize) + 32 + 16
        let patches = Dictionary(
            uniqueKeysWithValues: (0 ..< 4).map { (at + UInt64($0), UInt8(truncatingIfNeeded: marked >> (8 * $0))) }
        )
        let fileSystem = try ExtFileSystem(source: PatchedSource(base: image, patches: patches))
        guard case .found(let found) = try fileSystem.indexedLookup(lowest.name, in: sub) else {
            Issue.record("\(String(decoding: lowest.name, as: UTF8.self)) should be found in the next leaf")
            return
        }
        #expect(found.inode == lowest.inode)
        // A name whose hash is not continued is still absent: the next leaf is read only for the same hash.
        guard case .absent = try fileSystem.indexedLookup(Array("not-here".utf8), in: sub) else {
            Issue.record("a missing name should stay absent")
            return
        }
    }

    static func path(_ fileSystem: ExtFileSystem, _ path: String) throws -> UInt64 {
        var id = fileSystem.rootID
        for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        return id
    }
}
