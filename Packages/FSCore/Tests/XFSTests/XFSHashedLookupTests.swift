import FSCore
import Foundation
import Testing

@testable import XFS

/// Hashed lookup in XFS directories (roadmap 0037), as the kernel's `xfs_dir_lookup` does it: the name's
/// `xfs_da_hashname`, then the leaf (and node) blocks down to the data entry. The references: xfs_db's `hash` and the
/// kernel's own lookups (Scripts/make-test-images.inner.sh, the .names files).
@Suite struct XFSHashedLookupTests {
    static let images = ["xfs-hash", "xfs-hash-1k"]
    static let collision: UInt32 = 0x1C1C_3870

    /// Every line of TestImages/xfshash.txt: xfsprogs' `xfs_db hash` over names of 1 to 70 bytes, non-ASCII
    /// ones, and 1 to 8 bytes of 0xFF and of 0x81 (high bits where the shifted fields of a group of bytes overlap).
    @Test func everyNameHashMatchesXfsprogs() throws {
        let text = try String(contentsOf: ImageOracle.directory.appendingPathComponent("xfshash.txt"), encoding: .utf8)
        var checked = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            try #require(fields.count == 2, "\(line)")
            let expected = try #require(UInt32(fields[1].dropFirst(2), radix: 16))
            #expect(XFSDirectoryHash.hash(Hex.bytes(fields[0])) == expected, "\(fields[0])")
            checked += 1
        }
        #expect(checked == 91)
    }

    /// The images must hold each form the kernel makes, or matching them proves nothing: a single block, one leaf
    /// block (`LEAF1`, with stale entries of removed names), and node trees, one of them a run of one hash across leaves.
    @Test(arguments: images)
    func theImagesHoldEveryDirectoryForm(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        let dirBlockSize = UInt64(fileSystem.superblock.dirBlockSize)
        func leafBlock(_ path: String) throws -> (XFSInode, DiskBytes) {
            let inode = try fileSystem.inode(try XFSImageTests.path(fileSystem, path))
            #expect(inode.format != XFSInode.local, "\(path)")
            return (
                inode, DiskBytes(try fileSystem.mapped(inode, at: XFSDirectory.leafOffset, count: Int(dirBlockSize)))
            )
        }
        let block = try fileSystem.inode(try XFSImageTests.path(fileSystem, "block"))
        #expect(block.size == dirBlockSize)
        let (_, leaf) = try leafBlock("leaf")
        #expect(try leaf.be16(8) == 0x3DF1 && leaf.be16(58) > 0, "a LEAF1 block with stale entries")
        let (collide, node) = try leafBlock("collide")
        #expect(try node.be16(8) == 0x3EBE && node.be16(58) == 1 && node.be16(56) >= 2)
        for index in 0 ..< Int(try node.be16(56)) { #expect(try node.be32(64 + 8 * index) == Self.collision) }
        let entries = try fileSystem.listing(collide.number).entries
        #expect(entries.count == 1_080 && entries.allSatisfy { XFSDirectoryHash.hash($0.name) == Self.collision })
        let (_, deep) = try leafBlock("deep")
        #expect(try deep.be16(8) == 0x3EBE && deep.be16(58) == (image == "xfs-hash" ? 2 : 1))
    }

    /// A leaf directory of one data block is as large as a block directory: the form is told by where the data fork ends
    /// (xfs_dir2_format), not by the size. xfs-1k's dir/sub is one.
    @Test func aLeafDirectoryOfOneDataBlockIsNotABlockDirectory() throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image("xfs-1k"))
        let inode = try fileSystem.inode(try XFSImageTests.path(fileSystem, "dir/sub"))
        #expect(inode.size == UInt64(fileSystem.superblock.dirBlockSize))
        let leaf = DiskBytes(
            try fileSystem.mapped(inode, at: XFSDirectory.leafOffset, count: fileSystem.superblock.dirBlockSize)
        )
        #expect(try leaf.be16(8) == 0x3DF1)
        let names = try fileSystem.listing(inode.number).entries
        #expect(!names.isEmpty)
        for entry in names { #expect(try fileSystem.hashedLookup(entry.name, in: inode)?.inode == entry.inode) }
    }

    /// Every name the kernel made, found through the hash with the inode the kernel gives it.
    @Test(arguments: images)
    func everyNameTheKernelMadeIsFoundByHash(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        let text = try String(
            contentsOf: ImageOracle.directory.appendingPathComponent("\(image).names"),
            encoding: .utf8
        )
        var directories: [String: XFSInode] = [:]
        var (checked, wrong): (Int, [String]) = (0, [])
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try #require(fields.count == 3, "\(line)")
            let directory =
                try directories[fields[0]] ?? fileSystem.inode(try XFSImageTests.path(fileSystem, fields[0]))
            directories[fields[0]] = directory
            let found = try fileSystem.hashedLookup(Array(fields[1].utf8), in: directory)
            if found?.inode != UInt64(fields[2]) || found?.name != Array(fields[1].utf8) { wrong.append(String(line)) }
            checked += 1
        }
        #expect(wrong.isEmpty, "\(wrong.count) wrong, first \(wrong.prefix(3))")
        #expect(
            checked == (image == "xfs-hash" ? 252_540 : 5_840) + 3 * (Self.oneByte.count + Self.dotLed.count)
                - Self.removed(image)
        )
    }

    /// The one-byte and dot-led names the image script adds to block/, leaf/ and deep/ (after the removals): the shortest
    /// names, which shortform directories alone held before, and the names next to "." and "..".
    static let oneByte = "abcdefgh".map { [UInt8]($0.utf8) }
    /// Names that begin with dots but are not "." or "..", added with them: entries like any other.
    static let dotLed = ["...", ".a", "..a"].map { Array($0.utf8) }

    @Test(arguments: images)
    func oneByteAndDotLedNamesAreFoundInEveryForm(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        for (path, directory) in try Self.directories(fileSystem, ["block", "leaf", "deep"]) {
            let listed = try fileSystem.listing(directory.number).entries
            for name in Self.oneByte + Self.dotLed {
                let entry = try #require(listed.first { $0.name == name }, "\(path): \(name)")
                #expect(try fileSystem.hashedLookup(name, in: directory)?.inode == entry.inode, "\(path): \(name)")
            }
        }
    }

    /// The names removed after they were made (every tenth of leaf/, collide/ and deep/): the image script's arithmetic.
    static func removed(_ image: String) -> Int {
        let (leaf, deep) = image == "xfs-hash" ? (300, 250_000) : (600, 3_000)
        return leaf / 10 + 1_200 / 10 + deep / 10
    }

    /// A name of the same hash as `name` (of 3 bytes or more): bytes 1 and 2 changed so their changes cancel, 1 << 14
    /// either way.
    static func twin(_ name: [UInt8]) -> [UInt8]? {
        guard name.count >= 3 else { return nil }
        var twin = name
        twin[1] ^= 1
        twin[2] ^= 0x80
        return twin
    }

    /// The directories at `paths`, with their paths.
    static func directories(_ fileSystem: XFSFileSystem, _ paths: [String]) throws -> [(String, XFSInode)] {
        try paths.map { ($0, try fileSystem.inode(try XFSImageTests.path(fileSystem, $0))) }
    }

    /// The names the kernel made in xfs-hash's deep/, in the order of the .names file.
    static func deepNames() throws -> [[UInt8]] {
        let text = try String(
            contentsOf: ImageOracle.directory.appendingPathComponent("xfs-hash.names"),
            encoding: .utf8
        )
        return text.split(separator: "\n").filter { $0.hasPrefix("deep\t") }
            .map { Array($0.split(separator: "\t", omittingEmptySubsequences: false)[1].utf8) }
    }

    /// Names that are not there: removed ones (stale leaf entries), a byte longer, and of the same hash as one that is
    /// (bytes 1 and 2 changed so their changes cancel: 1 << 14 either way).
    @Test(arguments: images)
    func absentNamesAreNotFound(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        for (path, directory) in try Self.directories(fileSystem, ["block", "leaf", "collide", "deep", "targets"]) {
            for entry in try fileSystem.listing(directory.number).entries.prefix(50) {
                #expect(try fileSystem.hashedLookup(entry.name + [0x78], in: directory) == nil)
                guard let twin = Self.twin(entry.name) else { continue }
                #expect(XFSDirectoryHash.hash(twin) == XFSDirectoryHash.hash(entry.name))
                #expect(try fileSystem.hashedLookup(twin, in: directory) == nil, "\(path): \(twin)")
            }
        }
        let leaf = try fileSystem.inode(try XFSImageTests.path(fileSystem, "leaf"))
        let names = try fileSystem.listing(leaf.number).entries.map(\.name)
        let removed = (0 ..< (image == "xfs-hash" ? 300 : 600)).map { Array("n\($0)".utf8) }
            .filter { !names.contains($0) }
        #expect(removed.count == (image == "xfs-hash" ? 30 : 60))
        for name in removed { #expect(try fileSystem.hashedLookup(name, in: leaf) == nil) }
    }

    /// "." and ".." are not entries, as in the listing, in any form: they have hash leaf entries in leaf and node
    /// directories, but the kernel resolves them before it looks a directory up, and the shortform has none.
    @Test(arguments: images)
    func dotsAreNotEntries(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        for (path, directory) in try Self.directories(fileSystem, ["block", "leaf", "collide", "deep"]) {
            for name in [[0x2E], [0x2E, 0x2E]] as [[UInt8]] {
                #expect(try fileSystem.hashedLookup(name, in: directory) == nil, "\(path): \(name)")
            }
        }
    }

    /// The same answers as the listing in every directory of the tree images, shortform and block ones included.
    @Test(arguments: XFSImageTests.images)
    func everyDirectoryOfTheTreeImagesAgrees(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        var pending = [fileSystem.rootID]
        var (checked, wrong): (Int, [String]) = (0, [])
        while let id = pending.popLast() {
            let directory = try fileSystem.inode(id)
            for entry in try fileSystem.listing(id).entries {
                let found = try fileSystem.hashedLookup(entry.name, in: directory)
                if found?.inode != entry.inode || found?.type != entry.type { wrong.append("\(id): \(entry.name)") }
                if try fileSystem.inode(entry.inode).kind == .directory { pending.append(entry.inode) }
                checked += 1
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) wrong, first \(wrong.prefix(3))")
        #expect(checked > 10_000)
    }

    /// A lookup in the two-level node directory reads a few blocks and its extent map, not the directory's 6 MB, and
    /// builds no listing; a lookup in a directory already listed still answers.
    @Test func aLookupReadsAFewBlocksNotTheDirectory() throws {
        let names = try Self.deepNames()
        let name = names[names.count / 2]
        let counting = CountingSource(try ImageOracle.image("xfs-hash"))
        let fileSystem = try XFSFileSystem(source: counting)
        let deep = try XFSImageTests.path(fileSystem, "deep")
        let inode = try fileSystem.inode(deep)
        #expect(inode.size > 6_000_000)
        _ = try fileSystem.extents(inode)
        let (found, read) = try counting.measure { try fileSystem.lookup(name, in: deep) }
        #expect(found.name == name)
        #expect(read <= 4 * fileSystem.superblock.dirBlockSize, "\(read) bytes")
        #expect(fileSystem.listings[deep] == nil)
        #expect(throws: DiskError.notFound) { try fileSystem.lookup(Array("n250000".utf8), in: deep) }
    }

    /// A lookup that misses stops at the leaf where its hash's run ends: a name of the same hash as one just found reads
    /// nothing more (its blocks are cached), unless the run reaches the leaf's end, which a few names far apart cannot all
    /// do, and then at most the next leaf and its node. Each miss is bounded on its own, as a walk to the tree's end caches
    /// every leaf. A hash in no leaf reads at most its path down.
    @Test func aMissStopsAtItsLeaf() throws {
        let names = try Self.deepNames()
        let counting = CountingSource(try ImageOracle.image("xfs-hash"))
        let fileSystem = try XFSFileSystem(source: counting)
        let deep = try fileSystem.inode(try XFSImageTests.path(fileSystem, "deep"))
        var reads: [Int] = []
        for row in stride(from: 1_000, to: names.count, by: names.count / 5) {
            let name = names[row]
            let twin = try #require(Self.twin(name))
            #expect(try fileSystem.hashedLookup(name, in: deep)?.name == name)
            let (missed, read) = try counting.measure { try fileSystem.hashedLookup(twin, in: deep) }
            #expect(missed == nil)
            reads.append(read)
        }
        #expect(reads.min() == 0 && reads.allSatisfy { $0 <= 2 * fileSystem.superblock.dirBlockSize }, "\(reads)")
        let (absent, read) = try counting.measure { try fileSystem.hashedLookup(Array("n250000".utf8), in: deep) }
        #expect(absent == nil)
        #expect(read <= 3 * fileSystem.superblock.dirBlockSize, "\(read) bytes")
    }

    /// ASCII case-insensitive volumes hash names folded (xfs_ascii_ci_hashname): the kernel MacFS is checked against
    /// refuses to mount them and mkfs.xfs calls them deprecated, so with no reference they are refused, as v4 is.
    @Test func anAsciiCaseInsensitiveVolumeIsRefusedByName() throws {
        let source = try ImageOracle.image("xfs")
        let fileSystem = try XFSFileSystem(source: source)
        var raw = try source.read(at: 0, count: fileSystem.superblock.sectorSize)
        raw[0x64] |= 0x40
        let crc = try XFSChecksum.compute(DiskBytes(raw), at: 0xE0)
        for index in 0 ..< 4 { raw[0xE0 + index] = UInt8(truncatingIfNeeded: crc >> (8 * index)) }
        var patches: [UInt64: UInt8] = [:]
        for (index, byte) in raw.enumerated() { patches[UInt64(index)] = byte }
        #expect(throws: DiskError.unsupported("XFS ASCII case-insensitive volumes")) {
            try XFSFileSystem(source: PatchedSource(base: source, patches: patches))
        }
    }
}
