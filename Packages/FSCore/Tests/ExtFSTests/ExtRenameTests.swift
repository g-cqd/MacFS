import CrashTesting
import FSCore
import Foundation
import Testing

@testable import ExtFS

/// ext2 rename and hard links (roadmap 0026 step 3), in linear directories: POSIX's rules, and every crash state repairable.
@Suite struct ExtRenameTests {
    static func name(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func aFileIsRenamedInItsDirectory() throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let root = volume.rootID
        let hello = try volume.lookup(Self.name("hello.txt"), in: root).id
        try volume.rename(Self.name("hello.txt"), in: root, to: Self.name("greeting.txt"), in: root)
        #expect(try volume.lookup(Self.name("greeting.txt"), in: root).id == hello)
        #expect(throws: DiskError.notFound) { try volume.lookup(Self.name("hello.txt"), in: root) }
        try volume.close()
        try ExtNamespaceTests.e2fsck(device)
    }

    /// A directory moved to another parent: its `..` follows, both parents' link counts too.
    @Test func aDirectoryMovesToAnotherParent() throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let root = volume.rootID
        let big = try volume.lookup(Self.name("big"), in: root).id
        let moved = try volume.create(Self.name("moving"), kind: .directory, in: root, mode: 0o755, owner: (0, 0))
        let rootLinks = try volume.attributes(of: root).linkCount
        let bigLinks = try volume.attributes(of: big).linkCount
        try volume.rename(Self.name("moving"), in: root, to: Self.name("moved"), in: big)
        #expect(try volume.lookup(Self.name("moved"), in: big).id == moved)
        #expect(try volume.attributes(of: moved).parent == big)
        #expect(try volume.attributes(of: root).linkCount == rootLinks - 1)
        #expect(try volume.attributes(of: big).linkCount == bigLinks + 1)
        try volume.close()
        try ExtNamespaceTests.e2fsck(device)
    }

    /// Onto an existing file: the target's old file loses that name, and goes once it has none.
    @Test func aRenameReplacesAFile() throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let root = volume.rootID
        let free = try volume.statistics().freeBlocks
        let dir = try volume.lookup(Self.name("dir"), in: root).id
        let medium = try volume.lookup(Self.name("medium.txt"), in: dir).id
        let hundred = try volume.lookup(Self.name("hundred.txt"), in: dir).id
        try volume.rename(Self.name("hundred.txt"), in: dir, to: Self.name("medium.txt"), in: dir)
        #expect(try volume.lookup(Self.name("medium.txt"), in: dir).id == hundred)
        // medium.txt had a second name (big/medium-again.txt): it stays, with one link.
        #expect(try volume.attributes(of: medium).linkCount == 1)
        try volume.rename(Self.name("hello.txt"), in: root, to: Self.name("medium.txt"), in: dir)
        #expect(try volume.statistics().freeBlocks == free + 1, "hundred.txt's one block, freed with its last name")
        try volume.close()
        try ExtNamespaceTests.e2fsck(device)
    }

    @Test func renamesFollowPOSIX() throws {
        let (_, volume) = try ExtNamespaceTests.open()
        let root = volume.rootID
        let dir = try volume.lookup(Self.name("dir"), in: root).id
        // A linear subdirectory of dir (dir/sub is indexed, refused before this rule is reached).
        let sub = try volume.create(Self.name("plain"), kind: .directory, in: dir, mode: 0o755, owner: (0, 0))
        _ = try volume.create(Self.name("empty"), kind: .directory, in: root, mode: 0o755, owner: (0, 0))
        #expect(throws: DiskError.invalidName, "into its own subtree") {
            try volume.rename(Self.name("dir"), in: root, to: Self.name("inside"), in: sub)
        }
        #expect(throws: DiskError.isDirectory) {
            try volume.rename(Self.name("hello.txt"), in: root, to: Self.name("empty"), in: root)
        }
        #expect(throws: DiskError.notDirectory) {
            try volume.rename(Self.name("empty"), in: root, to: Self.name("hello.txt"), in: root)
        }
        #expect(throws: DiskError.notEmpty) {
            try volume.rename(Self.name("empty"), in: root, to: Self.name("dir"), in: root)
        }
        #expect(throws: DiskError.notFound) {
            try volume.rename(Self.name("absent"), in: root, to: Self.name("x"), in: root)
        }
        // Onto itself: nothing changes.
        try volume.rename(Self.name("hello.txt"), in: root, to: Self.name("hello.txt"), in: root)
        #expect(try volume.lookup(Self.name("hello.txt"), in: root).kind == .regular)
    }

    @Test func aHardLinkIsASecondName() throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let root = volume.rootID
        let hello = try volume.lookup(Self.name("hello.txt"), in: root).id
        try volume.link(hello, as: Self.name("hello-again.txt"), in: root)
        #expect(try volume.lookup(Self.name("hello-again.txt"), in: root).id == hello)
        #expect(try volume.attributes(of: hello).linkCount == 2)
        #expect(throws: DiskError.isDirectory) { try volume.link(root, as: Self.name("loop"), in: root) }
        #expect(throws: DiskError.exists) { try volume.link(hello, as: Self.name("dir"), in: root) }
        try volume.close()
        try ExtNamespaceTests.e2fsck(device)
    }

    static func crashStates(_ session: (ExtFileSystem) throws -> Void) throws -> [CrashState] {
        let original = try ExtWriteTests.copy("ext2")
        let setup = try ExtWriteTests.writable(original)
        _ = try setup.create(Self.name("moving"), kind: .directory, in: setup.rootID, mode: 0o755, owner: (0, 0))
        try setup.close()
        let recorder = CrashRecorder(original)
        let volume = try ExtWriteTests.writable(recorder)
        try session(volume)
        try volume.close()
        return recorder.crashStates()
    }

    /// `repair` then `e2fsck -fn` on every state: the repair exits 0 or 1 (fixed), the check after finds nothing.
    static func expectRepairable(_ states: [CrashState], by repair: [String]) throws {
        guard Checkers.isAvailable else { return }
        let images = Dictionary(
            uniqueKeysWithValues: states.enumerated().map { ("state\($0.offset)", $0.element.image()) }
        )
        let results = try #require(Checkers.run([repair, ["e2fsck", "-fn"]], on: images))
        for (index, state) in states.enumerated() {
            let steps = results["state\(index)"] ?? []
            #expect(steps.count == 2 && steps[0].status <= 1, "\(state.name): repair \(steps.first?.output ?? "")")
            #expect(steps.last?.status == 0, "\(state.name): after the repair \(steps.last?.output ?? "")")
        }
    }

    /// Renames within a directory (a file, a directory), one replacing a file, and a hard link: preen repairs every crash
    /// state.
    @Test func everyCrashStateOfRenamesAndLinksIsRepairedByPreen() throws {
        let states = try Self.crashStates { volume in
            let root = volume.rootID
            let dir = try volume.lookup(Self.name("dir"), in: root).id
            try volume.rename(Self.name("hello.txt"), in: root, to: Self.name("greeting.txt"), in: root)
            try volume.rename(Self.name("moving"), in: root, to: Self.name("renamed"), in: root)
            try volume.rename(Self.name("hundred.txt"), in: dir, to: Self.name("medium.txt"), in: dir)
            try volume.link(
                try volume.lookup(Self.name("greeting.txt"), in: root).id,
                as: Self.name("again.txt"),
                in: dir
            )
        }
        try Self.expectRepairable(states, by: ["e2fsck", "-fp"])
    }

    /// A directory moved to another parent: without a journal some crash states need `e2fsck -fy` (two names, or `..`
    /// behind), as on Linux's ext2; every one of them it repairs.
    @Test func everyCrashStateOfADirectoryMoveIsRepairedByE2fsck() throws {
        let states = try Self.crashStates { volume in
            let dir = try volume.lookup(Self.name("dir"), in: volume.rootID).id
            try volume.rename(Self.name("moving"), in: volume.rootID, to: Self.name("moved"), in: dir)
        }
        try Self.expectRepairable(states, by: ["e2fsck", "-fy"])
    }
}
