import FSCore
import Testing

@testable import XFS

/// What the images cannot reach (block numbers past 2^43, inode numbers past 2^32) on built bytes; and on the images,
/// inodes changed with their checksum recomputed, so only the check under test can catch them.
@Suite struct XFSStructureTests {
    /// An extent record's fields at their widest: 54-bit offset, 52-bit start block across both words, 21-bit count.
    @Test func anExtentRecordsFieldsAtTheirWidest() throws {
        let (offset, start, count): (UInt64, UInt64, UInt64) = (0x2A_BCDE_F012_3456, 0xF_EDCB_A987_6543, 0x1F_ABCD)
        let high = 1 << 63 | offset << 9 | start >> 43
        let low = (start & ((1 << 43) - 1)) << 21 | count
        let bytes = DiskBytes(
            (0 ..< 8).map { UInt8(truncatingIfNeeded: high >> (56 - 8 * $0)) }
                + (0 ..< 8).map { UInt8(truncatingIfNeeded: low >> (56 - 8 * $0)) }
        )
        let fields = try XFSExtent.fields(bytes, 0)
        #expect(fields.logical == offset && fields.start == start && fields.count == count && fields.unwritten)
        let written = try XFSExtent.fields(DiskBytes([0x7F] + Array(try bytes.bytes(1, 15))), 0)
        #expect(!written.unwritten)
    }

    /// A shortform directory whose inode numbers need 64 bits (i8count set): parent and entries 8 bytes wide.
    @Test func aShortformDirectoryWithWideInodeNumbers() throws {
        let parent: UInt64 = 0x1_0000_0080
        let child: UInt64 = 0x2_0000_0123
        func be64(_ value: UInt64) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) } }
        let fork = [1, 1] + be64(parent) + [3, 0, 0x60] + Array("abc".utf8) + [1] + be64(child)
        let (found, entries) = try XFSDirectory.shortform(DiskBytes(fork + [0, 0]), size: fork.count, fileType: true)
        #expect(found == parent)
        #expect(entries.map(\.inode) == [child] && entries.map(\.name) == [Array("abc".utf8)] && entries[0].type == 1)
    }

    /// An inode with `change` applied and its checksum recomputed: what the reader sees for it.
    static func rewritten(_ image: String, _ path: String, _ change: (inout [UInt8]) -> Void) throws -> (
        XFSFileSystem, UInt64
    ) {
        let layout = try XFSChecksumTests.Layout(image)
        let number = try XFSImageTests.path(layout.fileSystem, path)
        let at = layout.offset(of: number)
        var raw = try layout.source.read(at: at, count: layout.fileSystem.superblock.inodeSize)
        change(&raw)
        let crc = try XFSChecksum.compute(DiskBytes(raw), at: 100)
        for index in 0 ..< 4 { raw[100 + index] = UInt8(truncatingIfNeeded: crc >> (8 * index)) }
        var patches: [UInt64: UInt8] = [:]
        for (index, byte) in raw.enumerated() { patches[at + UInt64(index)] = byte }
        return (try XFSFileSystem(source: PatchedSource(base: layout.source, patches: patches)), number)
    }

    @Test func anInodeThatRecordsAnotherNumberIsRefused() throws {
        let (fileSystem, number) = try Self.rewritten("xfs", "hello.txt") { $0[159] ^= 1 }
        #expect(throws: DiskError.self) { try fileSystem.attributes(of: number) }
    }

    @Test func extentsOutOfOrderAreRefused() throws {
        let layout = try XFSChecksumTests.Layout("xfs")
        let inode = try layout.inode("big/preallocated.bin")
        #expect(inode.format == XFSInode.extents && inode.extentCount >= 2)
        let (fileSystem, number) = try Self.rewritten("xfs", "big/preallocated.bin") { raw in
            let first = Array(raw[176 ..< 192])
            raw.replaceSubrange(176 ..< 192, with: raw[192 ..< 208])
            raw.replaceSubrange(192 ..< 208, with: first)
        }
        #expect(throws: DiskError.self) { try fileSystem.read(number, at: 0, count: 16) }
    }

    /// Unwritten extents over freed random data: the stale bytes are there on the volume, and read as zero.
    @Test(arguments: XFSImageTests.images)
    func unwrittenExtentsReadAsZeroOverStaleBytes(_ image: String) throws {
        let layout = try XFSChecksumTests.Layout(image)
        let inode = try layout.inode("big/preallocated.bin")
        let unwritten = try layout.fileSystem.extents(inode).filter(\.unwritten)
        #expect(!unwritten.isEmpty)
        let stale = try unwritten.map {
            try layout.source.read(at: $0.physical * layout.blockSize, count: Int(layout.blockSize))
        }
        #expect(stale.contains { $0.contains { $0 != 0 } }, "the freed random data should lie beneath")
        let first = try #require(unwritten.first)
        let bytes = try layout.fileSystem.read(
            inode.number,
            at: first.logical * layout.blockSize,
            count: Int(layout.blockSize)
        )
        #expect(bytes.allSatisfy { $0 == 0 })
    }

    /// What the reference manifest does not carry: creation times and allocated sizes.
    @Test(arguments: XFSImageTests.images)
    func creationTimesAndAllocatedSizes(_ image: String) throws {
        let fileSystem = try XFSFileSystem(source: try ImageOracle.image(image))
        let hello = try fileSystem.attributes(of: try XFSImageTests.path(fileSystem, "hello.txt"))
        #expect(hello.created.seconds > 1_750_000_000 && hello.created.seconds <= hello.changed.seconds)
        #expect(hello.modified.seconds == 1_700_000_000 && hello.modified.nanoseconds == 123_456_789)
        let random = try fileSystem.attributes(of: try XFSImageTests.path(fileSystem, "big/random.bin"))
        let block = UInt64(fileSystem.superblock.blockSize)
        #expect(random.allocatedSize == (random.size + block - 1) / block * block)
    }

    @Test func aVersion4VolumeIsRefusedByName() throws {
        let source = try ImageOracle.image("xfs")
        let version = try source.read(at: 0x64, count: 2)
        let patched = PatchedSource(base: source, patches: [0x65: version[1] & 0xF0 | 4])
        #expect(throws: DiskError.unsupported("XFS v4 volumes")) { try XFSFileSystem(source: patched) }
    }
}
