import FSCore
import Testing

@testable import NTFS

@Suite struct NTFSImageTests {
    static let images = ["ntfs", "ntfs-lznt1"]

    @Test(arguments: images)
    func wholeTreeMatchesTheManifest(_ name: String) throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image(name))
        #expect(fileSystem.volume.label == name)
        try ImageOracle.expectMatch(fileSystem, manifest: name)
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

    /// A compressed stream initialized short of its size reads zeros past the initialized size, as a plain one does (ntfs-3g
    /// leaves its own compressed files initialized whole, so the attribute is rebuilt with a smaller initialized size).
    @Test func aCompressedStreamReadsZerosPastItsInitializedSize() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs-lznt1"))
        let big = try fileSystem.lookup(Array("big".utf8), in: fileSystem.rootID)
        let counting = try fileSystem.lookup(Array("counting.txt".utf8), in: big.id)
        let record = try fileSystem.record(counting.id)
        let data = try #require(record.first(NTFSAttributeType.data))
        let head = try #require(data.nonResident)
        #expect(data.flags & NTFSAttribute.compressed != 0 && head.compressionUnit == 4)
        let cut: UInt64 = 70_000  // inside the second compression unit
        let short = NTFSAttribute(
            type: data.type, name: data.name, flags: data.flags, value: nil,
            nonResident: NTFSAttribute.NonResident(
                firstVCN: head.firstVCN, runs: head.runs, allocatedSize: head.allocatedSize, dataSize: head.dataSize,
                initializedSize: cut, compressionUnit: head.compressionUnit))
        let stream = try NTFSStream([short], clusterSize: fileSystem.boot.clusterSize)
        let whole = try fileSystem.read(counting.id, at: 0, count: 200_000)
        let bytes = try stream.read(try ImageOracle.image("ntfs-lznt1"), at: 0, count: 200_000)
        #expect(Array(bytes[..<Int(cut)]) == Array(whole[..<Int(cut)]))
        #expect(bytes[Int(cut)...].allSatisfy { $0 == 0 } && bytes.count == 200_000)
    }
}
