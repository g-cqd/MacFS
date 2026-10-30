import FSCore
import Testing

@testable import Btrfs

@Suite struct BtrfsImageTests {
    static let images = ["btrfs", "btrfs-zlib", "btrfs-lzo", "btrfs-zstd", "btrfs-xxhash", "btrfs-subvol"]

    @Test(arguments: images)
    func wholeTreeMatchesTheManifest(_ name: String) throws {
        let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image(name))
        #expect(fileSystem.volume.label == name)
        try ImageOracle.expectMatch(fileSystem, manifest: name)
    }

    /// The compressed images must actually exercise decompression, or the manifest test proves nothing.
    @Test(arguments: [("btrfs-zlib", UInt8(1)), ("btrfs-lzo", UInt8(2)), ("btrfs-zstd", UInt8(3))])
    func compressedImagesHoldCompressedExtents(_ name: String, _ method: UInt8) throws {
        let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image(name))
        let big = try fileSystem.lookup(Array("big".utf8), in: fileSystem.rootID)
        let counting = try fileSystem.lookup(Array("counting.txt".utf8), in: big.id)
        #expect(try fileSystem.extents(counting.id).contains { $0.compression == method })
    }

    @Test func lookupMissesAndTypes() throws {
        let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image("btrfs"))
        #expect(throws: DiskError.notFound) { try fileSystem.lookup(Array("absent".utf8), in: fileSystem.rootID) }
        let hello = try fileSystem.lookup(Array("hello.txt".utf8), in: fileSystem.rootID)
        #expect(throws: DiskError.notDirectory) { try fileSystem.entries(of: hello.id, from: 0, limit: 10) }
        #expect(try fileSystem.read(hello.id, at: 6, count: 100) == Array("btrfs\n".utf8))
        #expect(try fileSystem.read(hello.id, at: 100, count: 100).isEmpty)
    }

    @Test func subvolumeRootIsItsOwnTree() throws {
        let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image("btrfs-subvol"))
        let volume = try fileSystem.lookup(Array("vol".utf8), in: fileSystem.rootID)
        #expect(volume.id >> 32 != 0, "the subvolume's root should be addressed in another tree")
        #expect(try fileSystem.attributes(of: volume.id).parent == fileSystem.rootID)
    }
}
