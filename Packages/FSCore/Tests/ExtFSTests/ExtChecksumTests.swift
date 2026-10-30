import FSCore
import Testing

@testable import ExtFS

/// An image read with some of its bytes changed: a corruption without a copy of the image.
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

/// ext4's metadata checksums (roadmap 0015): a real image reads (every other image test), and one byte changed in a group
/// descriptor, an inode, an extent block or a directory block is a `checksum` error, not a misread. ext2 has no checksums, so
/// the same change there reads silently.
@Suite struct ExtChecksumTests {
    /// Where a structure lies in an image, found from the raw bytes and the reader's own superblock.
    struct Layout {
        let source: FileBlockSource
        let fileSystem: ExtFileSystem
        var blockSize: UInt64 { UInt64(fileSystem.superblock.blockSize) }

        init(_ image: String) throws {
            source = try ImageOracle.image(image)
            fileSystem = try ExtFileSystem(source: source)
        }

        var descriptorTable: UInt64 { (fileSystem.superblock.firstDataBlock + 1) * blockSize }

        func inodeOffset(_ number: UInt64) throws -> UInt64 {
            let superblock = fileSystem.superblock
            let index = number - 1
            let group = index / UInt64(superblock.inodesPerGroup)
            let descriptor = DiskBytes(
                try source.read(at: descriptorTable + group * UInt64(superblock.descriptorSize), count: 64))
            let high = superblock.is64Bit ? UInt64(try descriptor.u32(0x28)) << 32 : 0
            let table = high | UInt64(try descriptor.u32(8))
            return table * blockSize + index % UInt64(superblock.inodesPerGroup) * UInt64(superblock.inodeSize)
        }

        func inode(_ path: String) throws -> ExtInode {
            var id = fileSystem.rootID
            for part in path.split(separator: "/") { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
            return try fileSystem.inode(id)
        }

        /// The physical block of the inode's first extent (or first index entry's child).
        func firstBlock(_ inode: ExtInode) throws -> UInt64 {
            let area = inode.blockArea
            if try area.u16(6) == 0 { return UInt64(try area.u16(12 + 6)) << 32 | UInt64(try area.u32(12 + 8)) }
            return UInt64(try area.u16(12 + 8)) << 32 | UInt64(try area.u32(12 + 4))
        }

        /// The physical block of an inode's logical block, by the reader's own map.
        func physical(_ inode: ExtInode, _ logical: UInt64) throws -> UInt64 {
            let run = try fileSystem.runs(inode).first { $0.logical <= logical && logical < $0.end }
            return try #require(run?.physical) + logical - (run?.logical ?? 0)
        }

        /// The byte at `offset` with its lowest bit flipped.
        func flipped(_ offset: UInt64) throws -> PatchedSource {
            let byte = try source.read(at: offset, count: 1)[0]
            return PatchedSource(base: source, patches: [offset: byte ^ 1])
        }
    }

    static func expectChecksumError(_ body: () throws -> Void, _ what: String) {
        do {
            try body()
            Issue.record("\(what): read without a checksum error")
        } catch let error as DiskError {
            if case .checksum = error { return }
            Issue.record("\(what): \(error), not a checksum error")
        } catch { Issue.record("\(what): \(error)") }
    }

    @Test func theImageCarriesEveryChecksummedStructure() throws {
        let layout = try Layout("ext4")
        #expect(layout.fileSystem.superblock.checksums != nil)
        for image in ["ext4-inline", "ext4-bigalloc", "ext4-uuid-seed"] {
            #expect(try ExtFileSystem(source: ImageOracle.image(image)).superblock.checksums != nil, "\(image)")
        }
        // Both ways to the seed: stored (csum_seed) and derived from the UUID.
        #expect(try ExtFileSystem(source: ImageOracle.image("ext4")).superblock.incompat & 0x2000 != 0)
        #expect(try ExtFileSystem(source: ImageOracle.image("ext4-uuid-seed")).superblock.incompat & 0x2000 == 0)
        let islands = try layout.inode("big/islands.bin")
        #expect(try islands.blockArea.u16(6) >= 1, "islands.bin should need an extent block outside its inode")
        #expect(try layout.inode("dir/sub").flags & ExtInode.indexFlag != 0, "dir/sub should be an htree directory")
    }

    @Test func aChangedGroupDescriptorIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let patched = try layout.flipped(layout.descriptorTable + 0x0C)  // the low free-blocks count of group 0
        Self.expectChecksumError({ _ = try ExtFileSystem(source: patched) }, "group descriptor")
    }

    @Test func aChangedInodeIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let number = try layout.fileSystem.lookup(Array("hello.txt".utf8), in: 2).id
        let patched = try layout.flipped(try layout.inodeOffset(number) + 0x08)  // atime
        let fileSystem = try ExtFileSystem(source: patched)
        Self.expectChecksumError({ _ = try fileSystem.attributes(of: number) }, "inode")
    }

    /// With 256-byte inodes the checksum has 32 bits: a change to the stored high half alone is caught.
    @Test func aChangedHighHalfOfAnInodeChecksumIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let number = try layout.fileSystem.lookup(Array("hello.txt".utf8), in: 2).id
        let patched = try layout.flipped(try layout.inodeOffset(number) + 0x83)  // i_checksum_hi, high byte
        let fileSystem = try ExtFileSystem(source: patched)
        Self.expectChecksumError({ _ = try fileSystem.attributes(of: number) }, "inode checksum, high half")
    }

    @Test func aChangedExtentBlockIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let islands = try layout.inode("big/islands.bin")
        let block = try layout.firstBlock(islands)
        let patched = try layout.flipped(block * layout.blockSize + 12 + 12)  // the second extent's first logical byte
        let fileSystem = try ExtFileSystem(source: patched)
        Self.expectChecksumError({ _ = try fileSystem.read(islands.number, at: 0, count: 16) }, "extent block")
    }

    @Test func aChangedDirectoryBlockIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let block = try layout.firstBlock(try layout.inode("dir"))
        let patched = try layout.flipped(block * layout.blockSize + 12 + 8 + 1)  // the second byte of ".."
        let fileSystem = try ExtFileSystem(source: patched)
        let dir = try layout.fileSystem.lookup(Array("dir".utf8), in: 2).id
        Self.expectChecksumError({ _ = try fileSystem.entries(of: dir, from: 0, limit: 100) }, "directory block")
    }

    /// A plain (unindexed) directory block must end with its checksum tail: one that does not is refused, as Linux does.
    @Test func aDirectoryBlockWithoutItsTailIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let directory = try layout.inode("dir")
        #expect(directory.flags & ExtInode.indexFlag == 0)
        let block = try layout.firstBlock(directory)
        let patched = try layout.flipped(block * layout.blockSize + layout.blockSize - 12 + 7)  // the tail's type, 0xDE
        let fileSystem = try ExtFileSystem(source: patched)
        Self.expectChecksumError(
            { _ = try fileSystem.entries(of: directory.number, from: 0, limit: 100) }, "tailless block")
    }

    /// An htree's index blocks carry a `dx_tail` after their entries (roadmap 0016): a changed hash in the root is caught.
    @Test func aChangedHtreeRootIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let sub = try layout.inode("dir/sub")
        #expect(sub.flags & ExtInode.indexFlag != 0)
        let root = try layout.physical(sub, 0)
        let patched = try layout.flipped(root * layout.blockSize + 32 + 8)  // the second dx_entry's hash
        let fileSystem = try ExtFileSystem(source: patched)
        Self.expectChecksumError({ _ = try fileSystem.entries(of: sub.number, from: 0, limit: 1000) }, "htree root")
    }

    /// An htree's leaves are plain directory blocks and need their tail like any other, as in Linux.
    @Test func anHtreeLeafWithoutItsTailIsAChecksumError() throws {
        let layout = try Layout("ext4")
        let sub = try layout.inode("dir/sub")
        let leaf = try layout.physical(sub, 1)
        let patched = try layout.flipped(leaf * layout.blockSize + layout.blockSize - 12 + 7)
        let fileSystem = try ExtFileSystem(source: patched)
        Self.expectChecksumError({ _ = try fileSystem.entries(of: sub.number, from: 0, limit: 1000) }, "htree leaf")
    }

    /// The kernel turns a full linear directory into an htree in place and writes only `dt_checksum`: the old leaf tail's
    /// bytes stay in `dt_reserved`, so the root's last 12 bytes look like a leaf tail. It is an index block all the same.
    @Test func aKernelMadeHtreeRootIsAnIndexBlock() throws {
        let layout = try Layout("ext4-grown")
        let sub = try layout.inode("dir/sub")
        #expect(sub.flags & ExtInode.indexFlag != 0)
        let root = DiskBytes(try layout.source.read(at: try layout.physical(sub, 0) * layout.blockSize, count: 1024))
        #expect(try root.u16(1024 - 8) == 12 && root.u8(1024 - 5) == 0xDE, "the stale tail should be there")
        #expect(try layout.fileSystem.entries(of: sub.number, from: 0, limit: 1000).count == 320)
    }

    @Test func withoutTheFeatureNothingIsChecked() throws {
        let layout = try Layout("ext2")
        #expect(layout.fileSystem.superblock.checksums == nil)
        let number = try layout.fileSystem.lookup(Array("hello.txt".utf8), in: 2).id
        let patched = try layout.flipped(try layout.inodeOffset(number) + 0x08)
        _ = try ExtFileSystem(source: patched).attributes(of: number)
    }
}
