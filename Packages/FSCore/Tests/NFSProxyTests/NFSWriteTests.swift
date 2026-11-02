import CrashTesting
import ExtFS
import FSCore
import NFSProxy
import Testing

/// Writes through the NFS proxy (roadmap 0046): with a writer, the export answers RFC 1813's changing procedures through it;
/// without one, every change is NFS3ERR_ROFS, as before. Each test ends with e2fsck on what the export wrote.
@Suite struct NFSWriteTests {
    static func e2fsck(_ session: NFSWriteSession) async throws {
        try session.volume.close()
        guard Checkers.isAvailable else { return }
        let result = try #require(
            await Checkers.run(["e2fsck", "-fn"], on: ["volume": session.device.bytes])?["volume"]
        )
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func withoutAWriterEveryChangeIsReadOnly() throws {
        let session = try NFSWriteSession(writable: false)
        #expect(try session.create("new.txt", how: 1).status == 30)
        #expect(try session.mkdir("folder").status == 30)
        var access = try session.call(4) {
            $0.opaque(session.root)
            $0.u32(0x3F)
        }
        #expect(try access.u32() == 0)
        try NFSWriteSession.skipPostOp(&access)
        #expect(try access.u32() & 0x1C == 0, "no modify, extend or delete")
    }

    @Test func aWritableExportGrantsModifyExtendAndDelete() throws {
        let session = try NFSWriteSession()
        var access = try session.call(4) {
            $0.opaque(session.root)
            $0.u32(0x3F)
        }
        #expect(try access.u32() == 0)
        try NFSWriteSession.skipPostOp(&access)
        #expect(try access.u32() == 0x3F)
    }

    @Test func aCreatedFileIsWrittenReadAndCommitted() async throws {
        let session = try NFSWriteSession()
        let made = try session.create("new.txt", how: 1, mode: 0o640)
        #expect(made.status == 0)
        let file = try #require(made.handle)
        let data = (0 ..< 10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let written = try session.write(file, at: 0, data, stable: 2)
        #expect(written.status == 0 && written.count == 10_000)
        #expect(written.committed == 2, "FILE_SYNC asked, FILE_SYNC answered")
        let unstable = try session.write(file, at: 10_000, [1, 2, 3], stable: 0)
        #expect(unstable.status == 0 && unstable.verifier == written.verifier)
        #expect(try session.read(file, at: 0, count: 20_000) == data + [1, 2, 3])
        let attributes = try session.getattr(file)
        #expect(attributes.size == 10_003 && attributes.mode & 0o7777 == 0o640 && attributes.type == 1)
        var commit = try session.call(21) {
            $0.opaque(file)
            $0.u64(0)
            $0.u32(0)
        }
        #expect(try commit.u32() == 0)
        try NFSWriteSession.skipWcc(&commit)
        #expect(try commit.fixed(8) == written.verifier, "the server did not restart: nothing to write again")
        try await Self.e2fsck(session)
    }

    @Test func createsAreGuardedUncheckedOrExclusive() async throws {
        let session = try NFSWriteSession()
        let file = try #require(try session.create("new.txt", how: 1).handle)
        _ = try session.write(file, at: 0, [1, 2, 3, 4], stable: 2)
        #expect(try session.create("new.txt", how: 1).status == 17, "GUARDED: NFS3ERR_EXIST")
        let again = try session.create("new.txt", how: 0, size: 0)
        #expect(again.status == 0 && again.handle == file, "UNCHECKED: the same file, its size set")
        #expect(try session.getattr(file).size == 0)
        let verifier: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let exclusive = try session.create("only.txt", how: 2, verifier: verifier)
        #expect(exclusive.status == 0)
        let retried = try session.create("only.txt", how: 2, verifier: verifier)
        #expect(retried.status == 0 && retried.handle == exclusive.handle, "a retransmission finds its own file")
        #expect(try session.create("only.txt", how: 2, verifier: [9, 9, 9, 9, 9, 9, 9, 9]).status == 17)
        try await Self.e2fsck(session)
    }

    @Test func directoriesLinksAndNamesChange() async throws {
        let session = try NFSWriteSession()
        let folder = try #require(try session.mkdir("folder").handle)
        #expect(try session.getattr(folder).type == 2)
        let file = try #require(try session.create("a.txt", how: 1).handle)
        let link = try session.symlink("link", to: "a.txt")
        #expect(link.status == 0)
        var readlink = try session.call(5) { $0.opaque(link.handle ?? []) }
        #expect(try readlink.u32() == 0)
        try NFSWriteSession.skipPostOp(&readlink)
        #expect(try readlink.string(maximum: 1024) == "a.txt")
        // RENAME a.txt to folder/b.txt; LINK it back as hard.txt.
        #expect(
            try session.status(14) {
                $0.opaque(session.root)
                $0.string("a.txt")
                $0.opaque(folder)
                $0.string("b.txt")
            } == 0
        )
        #expect(try session.lookup("a.txt").status == 2)
        #expect(try session.lookup("b.txt", in: folder).handle == file)
        #expect(
            try session.status(15) {
                $0.opaque(file)
                $0.opaque(session.root)
                $0.string("hard.txt")
            } == 0
        )
        // RMDIR of a directory that holds a file: NOTEMPTY; REMOVE of a directory: not a file; RMDIR of a file: NOTDIR.
        let rmdir = { (name: String, directory: [UInt8]) in
            try session.status(13) {
                $0.opaque(directory)
                $0.string(name)
            }
        }
        let remove = { (name: String, directory: [UInt8]) in
            try session.status(12) {
                $0.opaque(directory)
                $0.string(name)
            }
        }
        #expect(try rmdir("folder", session.root) == 66)
        #expect(try remove("folder", session.root) == 21)
        #expect(try rmdir("hard.txt", session.root) == 20)
        #expect(try remove("b.txt", folder) == 0)
        #expect(try rmdir("folder", session.root) == 0)
        #expect(try session.lookup("folder").status == 2)
        #expect(try session.read(try #require(session.lookup("hard.txt").handle), at: 0, count: 10) == [])
        #expect(try session.mkdir("x", in: file).status == 20, "MKDIR in a file: NOTDIR")
        #expect(
            try session.status(11) {
                $0.opaque(session.root)
                $0.string("node")
                $0.u32(6)  // NF3FIFO
                NFSWriteSession.sattr(&$0)
            } == 10_004,
            "MKNOD: NOTSUPP"
        )
        try await Self.e2fsck(session)
    }

    @Test func setattrChangesModeSizeAndTime() async throws {
        let session = try NFSWriteSession()
        let file = try #require(try session.create("new.txt", how: 1).handle)
        _ = try session.write(file, at: 0, [UInt8](repeating: 5, count: 9_000), stable: 2)
        #expect(
            try session.status(2) {
                $0.opaque(file)
                NFSWriteSession.sattr(&$0, mode: 0o600, size: 100, mtime: 1_700_000_000)
                $0.bool(false)  // no guard
            } == 0
        )
        let attributes = try session.getattr(file)
        #expect(attributes.mode & 0o7777 == 0o600 && attributes.size == 100)
        #expect(
            try session.volume
                .attributes(of: session.volume.lookup(Array("new.txt".utf8), in: session.volume.rootID).id).modified
                .seconds == 1_700_000_000
        )
        try await Self.e2fsck(session)
    }
}
