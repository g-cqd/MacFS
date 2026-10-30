import FSCore
import Formats
import Testing

@Suite struct DiskFormatTests {
    static let images: [(String, DiskFormat)] = [
        ("btrfs", .btrfs), ("btrfs-zstd", .btrfs), ("ntfs", .ntfs), ("ext2", .ext), ("ext3", .ext), ("ext4", .ext),
        ("ext4-inline", .ext), ("xfs", .xfs), ("xfs-1k", .xfs)
    ]

    @Test(arguments: images)
    func eachImageIsRecognizedAsItsFormatOnly(_ name: String, _ format: DiskFormat) throws {
        let source = try ImageOracle.image(name)
        #expect(DiskFormat.detect(source) == format)
        let probed = try #require(format.probe(source))
        #expect(probed.label == name)
        for other in DiskFormat.allCases where other != format { #expect(other.probe(source) == nil) }
    }

    @Test func shortNamesFitTheMountTypeLimitAndDoNotShadowTheSystem() {
        // MFSTYPENAMELEN is 16 including the terminator; macOS ships its own read-only "ntfs".
        for format in DiskFormat.allCases {
            #expect(format.shortName.utf8.count < 16)
            #expect(!["ntfs", "msdos", "exfat", "apfs", "hfs", "smbfs", "nfs", "webdav"].contains(format.shortName))
        }
    }

    @Test func zeroesAreNoFormat() {
        #expect(DiskFormat.detect(Zeroes(byteCount: 1 << 20)) == nil)
    }
}

struct Zeroes: BlockSource {
    let byteCount: UInt64
    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard offset + UInt64(count) <= byteCount else { throw .corrupt("past the end") }
        return [UInt8](repeating: 0, count: count)
    }
}
