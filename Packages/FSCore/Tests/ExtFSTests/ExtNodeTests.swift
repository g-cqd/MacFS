import CrashTesting
import FSCore
import Foundation
import Testing

@testable import ExtFS

/// ext2 symbolic links, sizes and attributes (roadmap 0026 step 3): what a mount path needs beyond names and bytes. Apps
/// truncate a file before writing it again; Finder sets modes and times.
@Suite struct ExtNodeTests {
    static func name(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Under 60 bytes the target lives in the inode (a fast symlink); longer, in a block of its own.
    @Test func symbolicLinksKeepTheirTargets() async throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let root = volume.rootID
        let short = Self.name("../somewhere/else")
        let long = Self.name(String(repeating: "deep/", count: 30) + "target")
        let fast = try volume.createSymlink(Self.name("short-link"), target: short, in: root, owner: (501, 20))
        let slow = try volume.createSymlink(Self.name("long-link"), target: long, in: root, owner: (501, 20))
        #expect(try volume.readLink(fast) == short)
        #expect(try volume.readLink(slow) == long)
        #expect(try volume.attributes(of: fast).kind == .symlink)
        #expect(try volume.inode(fast).sectors == 0)
        #expect(try volume.inode(slow).sectors == 2)
        try volume.remove(Self.name("long-link"), from: root)
        try volume.close()
        #expect(try ExtFileSystem(source: device).readLink(fast) == short)
        try await ExtNamespaceTests.e2fsck(device)
    }

    /// Shorter: the blocks past the end go back to the volume, and a later growth reads zeros where the old bytes were.
    @Test func aFileIsTruncatedAndItsBlocksFreed() async throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let counting = try ExtHtreeTests.path(volume, "big/counting.txt")
        let free = try volume.statistics().freeBlocks
        let blocks = try volume.inode(counting).sectors / 2
        let head = try volume.read(counting, at: 0, count: 1500)
        try volume.setSize(counting, to: 1500)
        #expect(try volume.attributes(of: counting).size == 1500)
        // Two data blocks of 1 KiB stay; every other data block and the indirect blocks go.
        #expect(try volume.statistics().freeBlocks == free + blocks - 2)
        try volume.setSize(counting, to: 3000)
        let grown = try volume.read(counting, at: 0, count: 3000)
        #expect(Array(grown[0 ..< 1500]) == head)
        #expect(grown[1500...].allSatisfy { $0 == 0 })
        try volume.setSize(counting, to: 0)
        #expect(try volume.inode(counting).sectors == 0)
        try volume.close()
        try await ExtNamespaceTests.e2fsck(device)
    }

    @Test func attributesChangeAndTheChangeTimeMoves() async throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let then = Timestamp(seconds: 1_700_000_000, nanoseconds: 5_000)
        try volume.setAttributes(
            hello,
            AttributeChanges(mode: 0o600, uid: 70_000, gid: 80_000, accessed: then, modified: then)
        )
        let attributes = try volume.attributes(of: hello)
        #expect(attributes.permissions == 0o600 && attributes.kind == .regular)
        #expect(attributes.uid == 70_000 && attributes.gid == 80_000)
        #expect(attributes.accessed == then && attributes.modified == then)
        #expect(attributes.changed == ExtWriteTests.now)
        try volume.close()
        try await ExtNamespaceTests.e2fsck(device)
    }

    /// Every crash state of a truncation and of symlinks made: preen repairs it, the check after finds nothing.
    @Test func everyCrashStateOfATruncationAndSymlinksIsRepaired() async throws {
        let states = try ExtRenameTests.crashStates { volume in
            try volume.setSize(try ExtHtreeTests.path(volume, "big/random.bin"), to: 300_000)
            _ = try volume.createSymlink(Self.name("fast"), target: Self.name("x"), in: volume.rootID, owner: (0, 0))
            _ = try volume.createSymlink(
                Self.name("slow"),
                target: [UInt8](repeating: 0x61, count: 200),
                in: volume.rootID,
                owner: (0, 0)
            )
        }
        try await ExtRenameTests.expectRepairable(states, by: ["e2fsck", "-fp"])
    }
}
