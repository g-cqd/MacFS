import FSCore
import Testing

@testable import ExtFS

@Suite struct ExtImageTests {
    static let images = [
        "ext2", "ext3", "ext4", "ext4-inline", "ext4-bigalloc", "ext4-uuid-seed", "ext4-meta-bg", "ext4-grown"
    ]

    @Test(arguments: images)
    func wholeTreeMatchesTheManifest(_ name: String) throws {
        let fileSystem = try ExtFileSystem(source: try ImageOracle.image(name))
        #expect(fileSystem.volume.label == name)
        try ImageOracle.expectMatch(fileSystem, manifest: name, extra: ["lost+found"])
    }

    /// Each image must exercise the mapping it exists for, or its manifest test proves nothing.
    @Test func imagesUseTheLayoutsTheyAreFor() throws {
        let ext2 = try ExtFileSystem(source: try ImageOracle.image("ext2"))
        let random2 = try ext2.inode(try path(ext2, "big/random.bin"))
        #expect(random2.flags & ExtInode.extentsFlag == 0, "ext2 should map blocks indirectly")
        #expect(
            ext2.superblock.blockSize == 1024 && random2.size > 268 * 1024,
            "the file should need a double-indirect block"
        )

        let ext4 = try ExtFileSystem(source: try ImageOracle.image("ext4"))
        #expect(try ext4.inode(try path(ext4, "big/random.bin")).flags & ExtInode.extentsFlag != 0)
        #expect(
            try ext4.inode(try path(ext4, "dir/sub")).flags & ExtInode.indexFlag != 0,
            "300 names should make an htree"
        )
        #expect(ext4.superblock.hasMetadataChecksums)

        let inline = try ExtFileSystem(source: try ImageOracle.image("ext4-inline"))
        #expect(try inline.inode(try path(inline, "hello.txt")).flags & ExtInode.inlineDataFlag != 0)
        let hundred = try inline.inode(try path(inline, "dir/hundred.txt"))
        #expect(
            hundred.flags & ExtInode.inlineDataFlag != 0 && hundred.size > 60,
            "needs bytes beyond i_block, in system.data"
        )
    }

    /// meta_bg must reach descriptors past the first metagroup, or the images prove only the old layout (roadmap 0016).
    @Test func metaBGImagesUseGroupsPastTheirFirstMetagroup() throws {
        for (name, firstMetaBG) in [("ext4-meta-bg", 0), ("ext4-grown", 1)] {
            let fileSystem = try ExtFileSystem(source: try ImageOracle.image(name))
            let superblock = fileSystem.superblock
            #expect(superblock.incompat & 0x0010 != 0, "\(name) should have meta_bg")
            #expect(superblock.firstMetaBG == UInt32(firstMetaBG), "\(name)")
            let perBlock = UInt64(superblock.blockSize / superblock.descriptorSize)
            var highest: UInt64 = 0
            for entry in try fileSystem.entries(of: fileSystem.rootID, from: 0, limit: 1000) {
                highest = max(highest, (entry.id - 1) / UInt64(superblock.inodesPerGroup) / perBlock)
            }
            #expect(highest >= 1, "\(name): every top-level inode is in the first metagroup")
        }
    }

    @Test func aDamagedSuperblockIsRefused() throws {
        let image = try ImageOracle.image("ext4")
        let damaged = FlippedByte(base: image, offset: 1024 + 0x78)
        #expect(throws: DiskError.checksum("superblock")) { try ExtFileSystem(source: damaged) }
    }

    @Test func lookupIsExactAndMissesThrow() throws {
        let fileSystem = try ExtFileSystem(source: try ImageOracle.image("ext4"))
        #expect(fileSystem.rootID == 2)
        #expect(throws: DiskError.notFound) { try fileSystem.lookup(Array("HELLO.TXT".utf8), in: fileSystem.rootID) }
        let hello = try fileSystem.lookup(Array("hello.txt".utf8), in: fileSystem.rootID)
        #expect(try fileSystem.read(hello.id, at: 0, count: 5) == Array("hello".utf8))
    }

    private func path(_ fileSystem: ExtFileSystem, _ path: String) throws -> UInt64 {
        var id = fileSystem.rootID
        for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        return id
    }
}

/// A source with one byte inverted, to show a checksum is checked.
struct FlippedByte: BlockSource {
    let base: any BlockSource
    let offset: UInt64
    var byteCount: UInt64 { base.byteCount }

    func read(at start: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        var bytes = try base.read(at: start, count: count)
        if offset >= start, offset < start + UInt64(count) { bytes[Int(offset - start)] ^= 0xFF }
        return bytes
    }
}
