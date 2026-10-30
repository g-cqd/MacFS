import FSCore
import Testing

@testable import XFS

/// An image read with some of its bytes changed.
struct PatchedSource: BlockSource {
    let base: any BlockSource
    let patches: [UInt64: UInt8]
    var byteCount: UInt64 { base.byteCount }

    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        var bytes = try base.read(at: offset, count: count)
        for (at, value) in patches where at >= offset && at < offset + UInt64(count) { bytes[Int(at - offset)] = value }
        return bytes
    }
}

/// v5 metadata checksums (CRC-32C, stored little-endian): one changed byte in the superblock, an inode, a data-fork B+tree
/// block, a directory data block or a remote symlink block is a `checksum` error, not a misread.
@Suite struct XFSChecksumTests {
    static func expectChecksumError(_ body: () throws -> Void, _ what: String) {
        do {
            try body()
            Issue.record("\(what): read without a checksum error")
        } catch let error as DiskError {
            if case .checksum = error { return }
            Issue.record("\(what): \(error), not a checksum error")
        } catch { Issue.record("\(what): \(error)") }
    }

    struct Layout {
        let source: FileBlockSource
        let fileSystem: XFSFileSystem
        init(_ image: String) throws {
            source = try ImageOracle.image(image)
            fileSystem = try XFSFileSystem(source: source)
        }
        var blockSize: UInt64 { UInt64(fileSystem.superblock.blockSize) }

        func inode(_ path: String) throws -> XFSInode {
            try fileSystem.inode(try XFSImageTests.path(fileSystem, path))
        }

        /// The byte offset of an inode on the volume, as the reader locates it.
        func offset(of inode: UInt64) -> UInt64 {
            let superblock = fileSystem.superblock
            let slotBits = UInt64(superblock.inodesPerBlockLog)
            let group = inode >> (UInt64(superblock.agBlockLog) + slotBits)
            let inGroup = inode >> slotBits & ((1 << UInt64(superblock.agBlockLog)) - 1)
            let block = group * UInt64(superblock.agBlocks) + inGroup
            return block * blockSize + (inode & ((1 << slotBits) - 1)) * UInt64(superblock.inodeSize)
        }

        func flipped(_ offset: UInt64) throws -> PatchedSource {
            PatchedSource(base: source, patches: [offset: try source.read(at: offset, count: 1)[0] ^ 1])
        }
    }

    @Test func aChangedSuperblockIsAChecksumError() throws {
        let layout = try Layout("xfs")
        let patched = try layout.flipped(0x6C)  // the label
        Self.expectChecksumError({ _ = try XFSFileSystem(source: patched) }, "superblock")
    }

    @Test func aChangedInodeIsAChecksumError() throws {
        let layout = try Layout("xfs")
        let hello = try layout.inode("hello.txt").number
        let fileSystem = try XFSFileSystem(source: try layout.flipped(layout.offset(of: hello) + 41))  // mtime
        Self.expectChecksumError({ _ = try fileSystem.attributes(of: hello) }, "inode")
    }

    @Test(arguments: ["xfs", "xfs-1k"])
    func aChangedBtreeBlockIsAChecksumError(_ image: String) throws {
        let layout = try Layout(image)
        let fragments = try layout.inode("big/fragments.bin")
        let root = fragments.dataFork
        let slots = (root.count - 4) / 16
        let child = try layout.fileSystem.superblock.diskBlock(try root.be64(4 + 8 * slots))
        let fileSystem = try XFSFileSystem(source: try layout.flipped(child * layout.blockSize + 72 + 3))  // a record
        Self.expectChecksumError({ _ = try fileSystem.read(fragments.number, at: 0, count: 16) }, "B+tree block")
    }

    @Test(arguments: ["xfs", "xfs-1k"])
    func aChangedDirectoryBlockIsAChecksumError(_ image: String) throws {
        let layout = try Layout(image)
        let sub = try layout.inode("dir/sub")
        let first = try #require(try layout.fileSystem.extents(sub).first)
        // "."
        let fileSystem = try XFSFileSystem(source: try layout.flipped(first.physical * layout.blockSize + 64 + 9))
        Self.expectChecksumError(
            { _ = try fileSystem.entries(of: sub.number, from: 0, limit: 1000) }, "directory block")
    }

    @Test func aChangedSymlinkBlockIsAChecksumError() throws {
        let layout = try Layout("xfs")
        let link = try layout.inode("dir/long-link")
        let first = try #require(try layout.fileSystem.extents(link).first)
        let fileSystem = try XFSFileSystem(source: try layout.flipped(first.physical * layout.blockSize + 56 + 5))
        Self.expectChecksumError({ _ = try fileSystem.readLink(link.number) }, "symlink block")
    }
}
