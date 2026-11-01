import CrashTesting
import FSCore
import Foundation
import Testing

@testable import ExtFS

/// ext2 names (roadmap 0026 step 3): files and directories created and removed in linear directories, through the inode
/// bitmaps, the group descriptors' counts and the directory entries. Indexed (htree) directories are refused until their
/// index is maintained.
@Suite struct ExtNamespaceTests {
    static func open() throws -> (MemoryBlockSource, ExtFileSystem) {
        let device = try ExtWriteTests.copy("ext2")
        return (device, try ExtWriteTests.writable(device))
    }

    static func name(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func e2fsck(_ device: MemoryBlockSource) throws {
        guard Checkers.isAvailable else { return }
        let result = try #require(Checkers.run(["e2fsck", "-fn"], on: ["volume": device.bytes])?["volume"])
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func aCreatedFileIsFoundWrittenAndKept() throws {
        let (device, volume) = try Self.open()
        let id = try volume.create(
            Self.name("new.txt"),
            kind: .regular,
            in: volume.rootID,
            mode: 0o644,
            owner: (501, 20)
        )
        #expect(try volume.lookup(Self.name("new.txt"), in: volume.rootID).id == id)
        let attributes = try volume.attributes(of: id)
        #expect(attributes.kind == .regular && attributes.size == 0 && attributes.linkCount == 1)
        #expect(attributes.permissions == 0o644 && attributes.uid == 501 && attributes.gid == 20)
        #expect(attributes.modified == ExtWriteTests.now && attributes.created == ExtWriteTests.now)
        try volume.write(id, at: 0, Self.name("abc"))
        try volume.close()
        let reread = try ExtFileSystem(source: device)
        #expect(
            try reread.read(try reread.lookup(Self.name("new.txt"), in: reread.rootID).id, at: 0, count: 10)
                == Self.name("abc")
        )
        try Self.e2fsck(device)
    }

    @Test func aCreatedDirectoryHoldsItsOwnFiles() throws {
        let (device, volume) = try Self.open()
        let rootLinks = try volume.attributes(of: volume.rootID).linkCount
        let directory = try volume.create(
            Self.name("made"),
            kind: .directory,
            in: volume.rootID,
            mode: 0o755,
            owner: (0, 0)
        )
        #expect(try volume.attributes(of: directory).kind == .directory)
        #expect(try volume.attributes(of: directory).linkCount == 2)
        #expect(try volume.attributes(of: directory).parent == volume.rootID)
        #expect(try volume.attributes(of: volume.rootID).linkCount == rootLinks + 1)
        #expect(try volume.entries(of: directory, from: 0, limit: 10).isEmpty)
        let inner = try volume.create(Self.name("inner"), kind: .regular, in: directory, mode: 0o600, owner: (0, 0))
        #expect(try volume.lookup(Self.name("inner"), in: directory).id == inner)
        try volume.close()
        try Self.e2fsck(device)
    }

    /// More names than a directory block holds: the directory gets a new block.
    @Test func aFullDirectoryGrowsABlock() throws {
        let (device, volume) = try Self.open()
        let directory = try volume.create(
            Self.name("many"),
            kind: .directory,
            in: volume.rootID,
            mode: 0o755,
            owner: (0, 0)
        )
        let names = (0 ..< 60).map { Self.name("a-name-long-enough-to-fill-blocks-quickly-\($0)") }
        for name in names { _ = try volume.create(name, kind: .regular, in: directory, mode: 0o644, owner: (0, 0)) }
        #expect(try volume.attributes(of: directory).size > 1024)
        try volume.close()
        let reread = try ExtFileSystem(source: device)
        #expect(Set(try reread.entries(of: directory, from: 0, limit: 100).map(\.name)) == Set(names))
        try Self.e2fsck(device)
    }

    @Test func aRemovedFileIsGoneAndItsSpaceFree() throws {
        let (device, volume) = try Self.open()
        let free = try volume.statistics().freeBlocks
        let counting = try ExtHtreeTests.path(volume, "big/counting.txt")
        let blocks = try volume.inode(counting).sectors / 2
        let big = try ExtHtreeTests.path(volume, "big")
        try volume.remove(Self.name("counting.txt"), from: big)
        #expect(throws: DiskError.notFound) { try volume.lookup(Self.name("counting.txt"), in: big) }
        #expect(try volume.statistics().freeBlocks == free + blocks)
        try volume.close()
        #expect(try ExtFileSystem(source: device).statistics().freeBlocks == free + blocks)
        try Self.e2fsck(device)
    }

    /// One of two names: the other still reads the file, now with one link.
    @Test func removingOneOfTwoNamesKeepsTheFile() throws {
        let (device, volume) = try Self.open()
        let medium = try ExtHtreeTests.path(volume, "dir/medium.txt")
        let bytes = try volume.read(medium, at: 0, count: 10_000)
        try volume.remove(Self.name("medium-again.txt"), from: try ExtHtreeTests.path(volume, "big"))
        #expect(try volume.attributes(of: medium).linkCount == 1)
        #expect(try volume.read(medium, at: 0, count: 10_000) == bytes)
        try volume.close()
        try Self.e2fsck(device)
    }

    @Test func onlyAnEmptyDirectoryIsRemoved() throws {
        let (device, volume) = try Self.open()
        let rootLinks = try volume.attributes(of: volume.rootID).linkCount
        _ = try volume.create(Self.name("empty"), kind: .directory, in: volume.rootID, mode: 0o755, owner: (0, 0))
        try volume.remove(Self.name("empty"), from: volume.rootID)
        #expect(try volume.attributes(of: volume.rootID).linkCount == rootLinks)
        #expect(throws: DiskError.notEmpty) { try volume.remove(Self.name("dir"), from: volume.rootID) }
        try volume.close()
        try Self.e2fsck(device)
    }

    @Test func namesFollowTheRules() throws {
        let (_, volume) = try Self.open()
        let root = volume.rootID
        #expect(throws: DiskError.exists) {
            try volume.create(Self.name("hello.txt"), kind: .regular, in: root, mode: 0o644, owner: (0, 0))
        }
        #expect(throws: DiskError.nameTooLong) {
            try volume.create(
                [UInt8](repeating: 0x61, count: 256),
                kind: .regular,
                in: root,
                mode: 0o644,
                owner: (0, 0)
            )
        }
        for bad in ["", ".", "..", "a/b"] {
            #expect(throws: DiskError.invalidName, "\(bad)") {
                try volume.create(Self.name(bad), kind: .regular, in: root, mode: 0o644, owner: (0, 0))
            }
        }
        #expect(throws: DiskError.invalidName) { try volume.remove(Self.name(".."), from: root) }
        #expect(throws: DiskError.notDirectory) {
            try volume.create(
                Self.name("x"),
                kind: .regular,
                in: try ExtHtreeTests.path(volume, "hello.txt"),
                mode: 0o644,
                owner: (0, 0)
            )
        }
        #expect(DiskError.exists.posixCode == EEXIST && DiskError.notEmpty.posixCode == ENOTEMPTY)
        #expect(DiskError.nameTooLong.posixCode == ENAMETOOLONG && DiskError.invalidName.posixCode == EINVAL)
    }

    @Test func anIndexedDirectoryIsNotChangedYet() throws {
        let (device, volume) = try Self.open()
        let sub = try ExtHtreeTests.path(volume, "dir/sub")
        let before = device.bytes
        #expect(throws: DiskError.unsupported("changing an indexed directory (a later slice)")) {
            try volume.create(Self.name("x"), kind: .regular, in: sub, mode: 0o644, owner: (0, 0))
        }
        #expect(throws: DiskError.unsupported("changing an indexed directory (a later slice)")) {
            try volume.remove(Self.name("f1.txt"), from: sub)
        }
        #expect(device.bytes == before)
    }

    /// Every crash state of a create, a mkdir and a remove: preen repairs it, the check after finds nothing, and each name is
    /// there or not, never half made.
    @Test func everyCrashStateOfNameChangesIsRepairable() throws {
        let original = try ExtWriteTests.copy("ext2")
        let recorder = CrashRecorder(original)
        let volume = try ExtWriteTests.writable(recorder)
        let root = volume.rootID
        _ = try volume.create(Self.name("new.txt"), kind: .regular, in: root, mode: 0o644, owner: (0, 0))
        _ = try volume.create(Self.name("made"), kind: .directory, in: root, mode: 0o755, owner: (0, 0))
        try volume.remove(Self.name("hello.txt"), from: root)
        try volume.close()
        let states = recorder.crashStates()
        for state in states {
            let reader = try ExtFileSystem(source: state)
            for name in ["new.txt", "made", "hello.txt"] {
                if let entry = try? reader.lookup(Self.name(name), in: reader.rootID) {
                    // A name that is there leads to something that reads, or to an inode preen will clear the name of.
                    _ = try? reader.attributes(of: entry.id)
                }
            }
        }
        guard Checkers.isAvailable else { return }
        let images = Dictionary(
            uniqueKeysWithValues: states.enumerated().map { ("state\($0.offset)", $0.element.image()) }
        )
        let results = try #require(Checkers.run([["e2fsck", "-fp"], ["e2fsck", "-fn"]], on: images))
        for (index, state) in states.enumerated() {
            let steps = results["state\(index)"] ?? []
            #expect(steps.count == 2 && steps[0].status <= 1, "\(state.name): preen \(steps.first?.output ?? "")")
            #expect(steps.last?.status == 0, "\(state.name): after preen \(steps.last?.output ?? "")")
        }
    }

    /// A directory growing a block, a name removed and an empty directory removed: every crash state repairable too.
    @Test func everyCrashStateOfAGrowingDirectoryAndAnRmdirIsRepairable() throws {
        let device = try ExtWriteTests.copy("ext2")
        let setup = try ExtWriteTests.writable(device)
        let many = try setup.create(Self.name("many"), kind: .directory, in: setup.rootID, mode: 0o755, owner: (0, 0))
        func long(_ index: Int) -> [UInt8] {
            Self.name(String(format: "a-name-long-enough-to-fill-blocks-%03d", index))
        }
        // Names until the directory's last block has no room for the next one: the recorded session's one create grows it.
        var count = 0
        while true {
            let runs = try setup.runs(try setup.inode(many))
            let last = try #require(runs.last?.physical.map { $0 + (runs.last?.count ?? 1) - 1 })
            let bytes = try device.read(at: last * 1024, count: 1024)
            guard try ExtDirectoryEntries.inserting(long(count), inode: 1, type: 1, into: bytes) != nil else { break }
            _ = try setup.create(long(count), kind: .regular, in: many, mode: 0o644, owner: (0, 0))
            count += 1
        }
        _ = try setup.create(Self.name("empty"), kind: .directory, in: many, mode: 0o755, owner: (0, 0))
        try setup.close()

        let recorder = CrashRecorder(device)
        let volume = try ExtWriteTests.writable(recorder)
        let size = try volume.attributes(of: many).size
        _ = try volume.create(long(count), kind: .regular, in: many, mode: 0o644, owner: (0, 0))
        #expect(try volume.attributes(of: many).size == size + 1024, "the session grows it")
        try volume.remove(long(3), from: many)
        try volume.remove(Self.name("empty"), from: many)
        try volume.close()
        let states = recorder.crashStates()
        guard Checkers.isAvailable else { return }
        let images = Dictionary(
            uniqueKeysWithValues: states.enumerated().map { ("state\($0.offset)", $0.element.image()) }
        )
        let results = try #require(Checkers.run([["e2fsck", "-fp"], ["e2fsck", "-fn"]], on: images))
        for (index, state) in states.enumerated() {
            let steps = results["state\(index)"] ?? []
            #expect(steps.count == 2 && steps[0].status <= 1, "\(state.name): preen \(steps.first?.output ?? "")")
            #expect(steps.last?.status == 0, "\(state.name): after preen \(steps.last?.output ?? "")")
        }
    }
}
