import FSCore
import Testing

@testable import XFS

/// XFS (roadmap 0031): every node of each image against its manifest and against the Linux kernel's view of it; the images
/// carry the structures they exist for; a changed byte in any checksummed structure is a checksum error, not a misread.
@Suite struct XFSImageTests {
    static let images = ["xfs", "xfs-1k"]

    @Test(arguments: images)
    func wholeTreeMatchesTheManifest(_ name: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(name))
        #expect(fileSystem.volume.label == name)
        try ImageOracle.expectMatch(fileSystem, manifest: name)
    }

    @Test(arguments: images)
    func everyNodeMatchesTheLinuxKernel(_ name: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(name))
        for problem in try ReferenceOracle.compare(fileSystem, reference: name) { Issue.record("\(name): \(problem)") }
    }

    static func path(_ fileSystem: XFSFileSystem, _ path: String) throws -> UInt64 {
        var id = fileSystem.rootID
        for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        return id
    }

    /// The images must hold each form, or matching them proves nothing (forks: 1 local, 2 extents, 3 B+tree).
    @Test(arguments: images)
    func theImagesHoldEveryForm(_ name: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(name))
        func format(_ path: String) throws -> UInt8 { try fileSystem.inode(try Self.path(fileSystem, path)).format }
        #expect(try format("dir") == 1, "a shortform directory")
        #expect(try format("dir/link") == 1, "an inline symlink")
        #expect(try format("dir/long-link") == 2, "a remote symlink")
        #expect(try format("big/fragments.bin") == 3, "a B+tree data fork")
        #expect(try format("many") == 3, "a node directory with a B+tree fork")
        // Block form: one directory block whose leaf closes it (XDB3); leaf form: data blocks (XDD3) and a leaf block at
        // 32 GiB.
        let forty = try fileSystem.inode(try Self.path(fileSystem, "forty"))
        let fortyBlock = try fileSystem.block(try #require(try fileSystem.extents(forty).first).physical)
        let fortyMagic = try fortyBlock.be32(0)
        #expect(forty.format == 2 && fortyMagic == 0x5844_4233, "a block-form directory")
        let sub = try fileSystem.inode(try Self.path(fileSystem, "dir/sub"))
        let leafBlock = XFSDirectory.leafOffset / UInt64(fileSystem.superblock.blockSize)
        #expect(try fileSystem.extents(sub).contains { $0.logical >= leafBlock }, "a leaf-form directory")
        #expect(fileSystem.superblock.hasCRC && fileSystem.superblock.hasFileType)
    }

    @Test func lookupIsExactAndMissesThrow() throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image("xfs"))
        #expect(throws: DiskError.notFound) { try fileSystem.lookup(Array("HELLO.TXT".utf8), in: fileSystem.rootID) }
        let hello = try fileSystem.lookup(Array("hello.txt".utf8), in: fileSystem.rootID)
        #expect(try fileSystem.read(hello.id, at: 0, count: 5) == Array("hello".utf8))
        #expect(throws: DiskError.notDirectory) { try fileSystem.entries(of: hello.id, from: 0, limit: 10) }
    }
}
