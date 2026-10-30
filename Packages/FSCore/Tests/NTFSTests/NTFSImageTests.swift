import FSCore
import Testing

@testable import NTFS

@Suite struct NTFSImageTests {
    @Test func wholeTreeMatchesTheManifest() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs"))
        #expect(fileSystem.volume.label == "ntfs")
        try ImageOracle.expectMatch(fileSystem, manifest: "ntfs")
    }

    /// The root holds 300+ names, so its index must spill out of $INDEX_ROOT into INDX blocks.
    @Test func rootIndexUsesIndexAllocation() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs"))
        let root = try fileSystem.record(fileSystem.rootID)
        #expect(root.attributes.contains { $0.type == NTFSAttributeType.indexAllocation })
    }

    @Test func lookupIsCaseInsensitiveAndPreservesCase() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs"))
        let exact = try fileSystem.lookup(Array("hello.txt".utf8), in: fileSystem.rootID)
        let folded = try fileSystem.lookup(Array("HELLO.TXT".utf8), in: fileSystem.rootID)
        #expect(exact.id == folded.id)
        #expect(folded.name == Array("hello.txt".utf8))
        #expect(throws: DiskError.notFound) { try fileSystem.lookup(Array("absent".utf8), in: fileSystem.rootID) }
    }

    @Test func systemFilesAreHidden() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs"))
        let names = try fileSystem.entries(of: fileSystem.rootID, from: 0, limit: 10_000).map(\.displayName)
        #expect(!names.contains { $0.hasPrefix("$") })
        #expect(names.contains("hello.txt"))
    }

    @Test func freeSpaceComesFromTheBitmap() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs"))
        let statistics = try fileSystem.statistics()
        #expect(statistics.totalBlocks > 0)
        #expect(statistics.freeBlocks > 0 && statistics.freeBlocks < statistics.totalBlocks)
    }
}
