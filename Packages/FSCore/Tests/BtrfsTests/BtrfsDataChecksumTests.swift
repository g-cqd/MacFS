import FSCore
import Testing

@testable import Btrfs

/// An image read with one byte changed (a corruption without a copy).
struct FlippedSource: BlockSource {
    let base: any BlockSource
    let offset: UInt64
    var byteCount: UInt64 { base.byteCount }

    func read(at start: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        var bytes = try base.read(at: start, count: count)
        if offset >= start, offset < start + UInt64(count) { bytes[Int(offset - start)] ^= 0x01 }
        return bytes
    }
}

/// Btrfs data checksums (roadmap 0015): the csum tree's checksum of every sector a file reads, as Linux verifies them
/// (fs/btrfs/file-item.c, inode.c). One changed byte in a file's data is a `checksum` error, whatever the checksum type, and
/// for a compressed extent the compressed bytes are what is checked.
@Suite struct BtrfsDataChecksumTests {
    /// The image offset of the first on-disk byte of `path`'s first regular extent, and the file's node.
    static func firstDataByte(_ image: String, _ path: String) throws -> (offset: UInt64, id: UInt64, compressed: Bool)
    {
        let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image(image))
        var id = fileSystem.rootID
        for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        for extent in try fileSystem.extents(id) {
            if case .regular(let address, _, _) = extent.storage, address != 0 {
                return (try fileSystem.trees.chunks.physical(address + 100, length: 1), id, extent.compression != 0)
            }
        }
        throw DiskError.notFound
    }

    @Test(arguments: [
        ("btrfs", "big/random.bin", false), ("btrfs-xxhash", "big/random.bin", false),
        ("btrfs-zlib", "big/counting.txt", true), ("btrfs-lzo", "big/counting.txt", true)
    ])
    func aChangedDataByteIsAChecksumError(_ image: String, _ path: String, _ compressed: Bool) throws {
        let (offset, id, isCompressed) = try Self.firstDataByte(image, path)
        #expect(
            isCompressed == compressed,
            "\(image): \(path) should exercise a \(compressed ? "compressed" : "plain") extent"
        )
        let fileSystem = try BtrfsFileSystem(source: FlippedSource(base: try ImageOracle.image(image), offset: offset))
        do {
            _ = try fileSystem.read(id, at: 0, count: 1 << 20)
            Issue.record("\(image): read without a checksum error")
        } catch {
            if case .checksum = error { return }
            Issue.record("\(image): \(error), not a checksum error")
        }
    }

    @Test func theImagesCarryAChecksumTree() throws {
        for image in ["btrfs", "btrfs-xxhash", "btrfs-zlib"] {
            let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image(image))
            #expect(fileSystem.dataChecksums.root != nil, "\(image)")
        }
    }
}
