import CrashTesting
import FSCore
import Foundation
import Testing

@testable import ExtFS

/// ext2 writes, first slice (roadmap 0026, ADR-0018): bytes overwritten inside a file's blocks, its times moved, and the
/// volume marked not clean while writable, clean at close, as Linux does for a volume without a journal. Each test works on
/// a copy of the image in memory; the format's own checker judges the result.
@Suite struct ExtWriteTests {
    static let now = Timestamp(seconds: 1_800_000_000, nanoseconds: 123_456_700)

    static func copy(_ name: String) throws -> MemoryBlockSource {
        let image = try ImageOracle.image(name)
        return MemoryBlockSource(try image.read(at: 0, count: Int(image.byteCount)))
    }

    static func writable(_ device: any WritableBlockSource) throws -> ExtFileSystem {
        try ExtFileSystem(writable: device, clock: { now })
    }

    static func state(_ device: some BlockSource) throws -> UInt16 {
        try DiskBytes(try device.read(at: 1024, count: 1024)).u16(0x3A)
    }

    // MARK: Refusals

    /// What this slice does not maintain is refused by name: a journal (jbd2 comes next), metadata checksums, a volume not
    /// cleanly unmounted, a device opened read-only.
    @Test func whatTheWriterDoesNotMaintainIsRefused() throws {
        #expect(throws: DiskError.unsupported("writing a volume with a journal (ext3/ext4)")) {
            try Self.writable(try Self.copy("ext3"))
        }
        #expect(throws: DiskError.self) { try Self.writable(try Self.copy("ext4")) }
        let dirty = try Self.copy("ext2")
        try dirty.write(at: 1024 + 0x3A, [0, 0])
        #expect(throws: DiskError.unsupported("writing a volume not cleanly unmounted: run e2fsck")) {
            try Self.writable(dirty)
        }
        #expect(throws: DiskError.readOnly) {
            try ExtFileSystem(writable: try ImageOracle.image("ext2"), clock: { Self.now })
        }
    }

    /// metadata_csum without a journal: an ext4 copy with its journal flags cleared and its superblock checksum redone.
    @Test func metadataChecksumsAreRefusedForNow() throws {
        let device = try Self.copy("ext4")
        var raw = try device.read(at: 1024, count: 1024)
        raw[0x5C] &= ~0x04  // has_journal
        raw[0x60] &= ~0x04  // needs_recovery
        let checksum = CRC32C.update(~0, raw[0 ..< 0x3FC])
        raw.replaceSubrange(0x3FC ..< 0x400, with: (0 ..< 4).map { UInt8(truncatingIfNeeded: checksum >> (8 * $0)) })
        try device.write(at: 1024, raw)
        #expect(throws: DiskError.unsupported("writing a volume with metadata checksums")) { try Self.writable(device) }
    }

    /// A read-only-compatible feature the writer does not know: the reader may read it, the writer must not write it.
    @Test func anUnknownReadOnlyFeatureIsRefused() throws {
        let device = try Self.copy("ext2")
        var raw = try device.read(at: 1024, count: 1024)
        raw[0x67] |= 0x80  // ro_compat bit 31
        try device.write(at: 1024, raw)
        _ = try ExtFileSystem(source: device)
        #expect(throws: DiskError.unsupported("writing a volume with read-only features 0x80000000")) {
            try Self.writable(device)
        }
    }

    /// Multiple-mount protection: the reader reads such a volume; the writer would have to keep the MMP block alive.
    @Test func multipleMountProtectionIsRefused() throws {
        let device = try Self.copy("ext2")
        var raw = try device.read(at: 1024, count: 1024)
        raw[0x61] |= 0x01  // incompat 0x100
        try device.write(at: 1024, raw)
        _ = try ExtFileSystem(source: device)
        #expect(throws: DiskError.unsupported("writing a volume with multiple-mount protection")) {
            try Self.writable(device)
        }
    }

    /// A fast symlink keeps its target in the inode's block area: written as a file, that text would be taken for block
    /// numbers. Refused, and nothing written.
    @Test func aSymlinkOrAnInlineFileIsNotWrittenAsBlocks() throws {
        let device = try Self.copy("ext2")
        let volume = try Self.writable(device)
        let before = device.bytes
        let link = try ExtHtreeTests.path(volume, "dir/link")
        // The named refusal, not just an error: this link's target, read as a block number, happens to lie past the end.
        #expect(throws: DiskError.unsupported("writing a symlink")) { try volume.write(link, at: 0, [1]) }
        // An inline-data file (the flag set on hello.txt's inode): its bytes are in the inode, not in blocks.
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let location = try volume.inodeLocation(hello)
        let flags = UInt64(location.block) * 1024 + UInt64(location.offset) + 0x23
        try device.write(at: flags, [try device.read(at: flags, count: 1)[0] | 0x10])
        volume.blocks.invalidate(location.block)
        let patched = device.bytes
        #expect(throws: DiskError.unsupported("writing an inline or encrypted file")) {
            try volume.write(hello, at: 0, [1])
        }
        #expect(device.bytes == patched)
        #expect(patched.indices.filter { patched[$0] != before[$0] } == [Int(flags)])
    }

    /// Where a write lands: runs of an extent-mapped file, contiguous or not; a gap or a hole is no place to write.
    @Test func piecesFollowTheRunsAndStopAtAGap() {
        let runs = [
            ExtRun(logical: 0, physical: 100, count: 2), ExtRun(logical: 2, physical: 500, count: 1),
            ExtRun(logical: 4, physical: 700, count: 1)
        ]
        let pieces = ExtFileSystem.pieces(of: runs, from: 1000, to: 2100, blockSize: 1024)
        #expect(pieces?.map(\.at) == [100 * 1024 + 1000, 500 * 1024])
        #expect(pieces?.map(\.from) == [0, 1048])
        #expect(pieces?.map(\.to) == [1048, 1100])
        #expect(ExtFileSystem.pieces(of: runs, from: 3000, to: 4200, blockSize: 1024) == nil, "block 3 is in a gap")
        #expect(
            ExtFileSystem.pieces(of: Array(runs.prefix(1)), from: 0, to: 3 * 1024, blockSize: 1024) == nil,
            "past the runs"
        )
        let hole = [ExtRun(logical: 0, physical: nil, count: 4)]
        #expect(ExtFileSystem.pieces(of: hole, from: 0, to: 10, blockSize: 1024) == nil)
    }

    // MARK: Overwrites

    @Test func anOverwriteIsReadBackAndMovesTheFilesTimes() throws {
        let device = try Self.copy("ext2")
        let volume = try Self.writable(device)
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        try volume.write(hello, at: 0, Array("HELLO".utf8))
        #expect(try volume.read(hello, at: 0, count: 64) == Array("HELLO btrfs\n".utf8))
        let attributes = try volume.attributes(of: hello)
        #expect(attributes.modified == Self.now)
        #expect(attributes.changed == Self.now)
        try volume.close()
        let reread = try ExtFileSystem(source: device)
        #expect(try reread.read(hello, at: 0, count: 64) == Array("HELLO btrfs\n".utf8))
        #expect(try reread.attributes(of: hello).modified == Self.now)
    }

    /// Across block boundaries of a file mapped through indirect blocks: exactly the bytes asked change.
    @Test func anOverwriteAcrossBlocksChangesOnlyThoseBytes() throws {
        let device = try Self.copy("ext2")
        let volume = try Self.writable(device)
        let counting = try ExtHtreeTests.path(volume, "big/counting.txt")
        let before = try volume.read(counting, at: 0, count: 300_000)
        let patch = [UInt8](repeating: 0x2A, count: 3000)
        try volume.write(counting, at: 1000, patch)
        try volume.close()
        var expected = before
        expected.replaceSubrange(1000 ..< 4000, with: patch)
        #expect(try ExtFileSystem(source: device).read(counting, at: 0, count: 300_000) == expected)
    }

    /// Growing a file, filling a hole and writing a directory need allocation, a later slice: refused, nothing written.
    @Test func whatNeedsAllocationIsRefusedForNow() throws {
        let device = try Self.copy("ext2")
        let original = device.bytes
        let volume = try Self.writable(device)
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        #expect(throws: DiskError.self) { try volume.write(hello, at: 10, Array("longer than it was".utf8)) }
        let sparse = try ExtHtreeTests.path(volume, "big/sparse.bin")
        #expect(throws: DiskError.self) { try volume.write(sparse, at: 4096, [1]) }
        #expect(throws: DiskError.isDirectory) { try volume.write(volume.rootID, at: 0, [1]) }
        try volume.close()
        // Only the superblock's mount fields differ: the state is back to clean, the times and the mount count moved.
        let written = device.bytes
        let changed = original.indices.filter { original[$0] != written[$0] }
        #expect(changed.allSatisfy { (1024 ..< 2048).contains($0) })
    }

    // MARK: The volume's state

    @Test func theVolumeIsNotCleanWhileWritableAndCleanAfterClose() throws {
        let device = try Self.copy("ext2")
        let mounts = try DiskBytes(try device.read(at: 1024, count: 1024)).u16(0x34)
        let volume = try Self.writable(device)
        #expect(try Self.state(device) & 1 == 0)
        #expect(try DiskBytes(try device.read(at: 1024, count: 1024)).u16(0x34) == mounts + 1)
        #expect(try DiskBytes(try device.read(at: 1024, count: 1024)).u32(0x2C) == UInt32(Self.now.seconds))
        try volume.close()
        #expect(try Self.state(device) & 1 == 1)
        #expect(try DiskBytes(try device.read(at: 1024, count: 1024)).u32(0x30) == UInt32(Self.now.seconds))
    }

    /// After the unmount, nothing more is written: the volume was declared clean.
    @Test func nothingIsWrittenAfterClose() throws {
        let volume = try Self.writable(try Self.copy("ext2"))
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        try volume.close()
        #expect(throws: DiskError.readOnly) { try volume.write(hello, at: 0, [1]) }
        #expect(throws: DiskError.readOnly) { try volume.close() }
    }

    // MARK: The oracle

    @Test(.enabled(if: Checkers.isAvailable)) func e2fsckAcceptsTheVolumeAfterWrites() throws {
        let device = try Self.copy("ext2")
        let volume = try Self.writable(device)
        try volume.write(try ExtHtreeTests.path(volume, "hello.txt"), at: 0, Array("HELLO".utf8))
        try volume.write(
            try ExtHtreeTests.path(volume, "big/counting.txt"),
            at: 1000,
            [UInt8](repeating: 0x2A, count: 3000)
        )
        try volume.close()
        let result = try #require(Checkers.run(["e2fsck", "-fn"], on: ["written": device.bytes])?["written"])
        #expect(result.status == 0, "\(result.output)")
    }

    /// Every state a power loss could leave (ADR-0018 decision 6): our reader opens it and reads the file as old or new bytes,
    /// block by block; e2fsck finds nothing wrong (a volume not clean is checked, not refused).
    @Test func everyCrashStateIsAVolumeE2fsckAccepts() throws {
        let original = try Self.copy("ext2")
        let mounts = try DiskBytes(try original.read(at: 1024, count: 1024)).u16(0x34)
        let recorder = CrashRecorder(original)
        let volume = try Self.writable(recorder)
        let counting = try ExtHtreeTests.path(volume, "big/counting.txt")
        let before = try volume.read(counting, at: 0, count: 4096)
        try volume.write(counting, at: 1000, [UInt8](repeating: 0x2A, count: 2100))
        try volume.close()
        let states = recorder.crashStates()
        #expect(states.count > 4)
        // No change is on disk without the mount on disk: wherever the inode's new time is, the superblock has counted the
        // mount (and says not clean, until the unmount says clean again).
        for state in states where try ExtFileSystem(source: state).attributes(of: counting).modified == Self.now {
            #expect(try DiskBytes(try state.read(at: 1024, count: 1024)).u16(0x34) == mounts + 1, "\(state.name)")
        }
        // And the volume never says clean before every change has landed: a state with the unmount recorded (clean, with
        // its time) holds the final bytes and times.
        let final = try ExtFileSystem(source: original).read(counting, at: 0, count: 4096)
        for state in states {
            let superblock = DiskBytes(try state.read(at: 1024, count: 1024))
            guard try superblock.u16(0x3A) & 1 == 1, try superblock.u32(0x30) == UInt32(Self.now.seconds) else {
                continue
            }
            let volume = try ExtFileSystem(source: state)
            #expect(try volume.read(counting, at: 0, count: 4096) == final, "\(state.name)")
            #expect(try volume.attributes(of: counting).modified == Self.now, "\(state.name)")
        }
        for state in states {
            let read = try ExtFileSystem(source: state).read(counting, at: 0, count: 4096)
            for block in 0 ..< 4 {
                let range = block * 1024 ..< (block + 1) * 1024
                let after = (0 ..< 1024)
                    .map { index -> UInt8 in
                        let at = block * 1024 + index
                        return (1000 ..< 3100).contains(at) ? 0x2A : before[at]
                    }
                #expect(
                    Array(read[range]) == Array(before[range]) || Array(read[range]) == after,
                    "\(state.name), block \(block)"
                )
            }
        }
        guard Checkers.isAvailable else { return }
        let images = Dictionary(
            uniqueKeysWithValues: states.enumerated().map { ("state\($0.offset)", $0.element.image()) }
        )
        let results = try #require(Checkers.run(["e2fsck", "-fn"], on: images))
        for (index, state) in states.enumerated() {
            let result = results["state\(index)"]
            #expect(result?.status == 0, "\(state.name): \(result?.output ?? "no result")")
        }
    }
}
