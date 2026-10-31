import Dispatch
import FSCore
import Foundation
import Synchronization
import Testing

@testable import Btrfs

/// Concurrent reads (the NFS proxy answers a connection's calls concurrently, roadmap 0038) verify a data piece once: eight
/// readers of one MiB of `big/random.bin` read it once to verify it, not eight times.
@Suite struct BtrfsConcurrentVerifyTests {
    /// `big/random.bin` of the btrfs image over `source`: 3,072,000 bytes in uncompressed extents of 1 MiB (mkfs.btrfs
    /// `--rootdir` writes no larger), the first two adjacent on disk.
    static func randomFile(_ source: any BlockSource) throws -> (BtrfsFileSystem, UInt64, first: UInt64) {
        let fileSystem = try BtrfsFileSystem(source: source)
        var id = fileSystem.rootID
        for part in ["big", "random.bin"] { id = try fileSystem.lookup(Array(part.utf8), in: id).id }
        var addresses: [UInt64] = []
        for extent in try fileSystem.extents(id) {
            if case .regular(let address, let length, _) = extent.storage, extent.compression == 0, length == 1 << 20 {
                addresses.append(address)
            }
        }
        try #require(addresses.count >= 2 && addresses[1] == addresses[0] + (1 << 20), "\(addresses)")
        return (fileSystem, id, addresses[0])
    }

    @Test func concurrentReadsOfOnePieceVerifyItOnce() throws {
        let source = CountingSource(try ImageOracle.image("btrfs"), slowLargeReads: true)
        let (fileSystem, id, _) = try Self.randomFile(source)
        _ = try fileSystem.read(id, at: 2 << 20, count: 4_096)  // metadata and checksum items warm, another piece
        let before = source.bytes.load(ordering: .relaxed)
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            do { _ = try fileSystem.read(id, at: UInt64(index) << 17, count: 4_096) } catch {
                failures.withLock { $0.append("\(error)") }
            }
        }
        let read = source.bytes.load(ordering: .relaxed) - before
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(read < 2 << 20, "\(read) bytes: the piece verified \(read >> 20) times")
        #expect(read >= 1 << 20, "\(read) bytes: the piece was verified")
    }

    /// A read that covers a piece whole is checked from its own bytes: the piece is not read a second time to verify it.
    @Test func aWholePieceIsReadOnce() throws {
        let source = CountingSource(try ImageOracle.image("btrfs"), slowLargeReads: true)
        let (fileSystem, id, _) = try Self.randomFile(source)
        _ = try fileSystem.read(id, at: 0, count: 4_096)
        let before = source.bytes.load(ordering: .relaxed)
        #expect(try fileSystem.read(id, at: 1 << 20, count: 1 << 20).count == 1 << 20)
        let read = source.bytes.load(ordering: .relaxed) - before
        #expect(read < 3 << 19, "\(read) bytes for one MiB")
    }

    /// A changed byte in the second piece of an extent, read from inside that piece, is a checksum error: pieces past the first
    /// are found and verified where they are. The test images hold no extent over 1 MiB, so the two adjacent extents of
    /// `random.bin` stand for one of 2 MiB, as Linux writes them up to 128 MiB.
    @Test func aChangeInALaterPieceIsFound() throws {
        let base = try ImageOracle.image("btrfs")
        let (clean, _, first) = try Self.randomFile(base)
        let changed = try clean.trees.chunks.physical(first + (1 << 20) + 100, length: 1)
        let (fileSystem, _, _) = try Self.randomFile(FlippedSource(base: base, offset: changed))
        let checks = fileSystem.dataChecksums
        do {
            try checks.verify(diskStart: first, diskLength: 2 << 20, from: first + (1 << 20) + 64, count: 4_096)
            Issue.record("verified without a checksum error")
        } catch {
            guard case .checksum = error else {
                Issue.record("\(error)")
                return
            }
        }
        // The first piece is clean, read to its last byte: the second is not touched.
        try checks.verify(diskStart: first, diskLength: 2 << 20, from: first, count: 1 << 20)
        do {  // one byte into the second piece reaches it
            try checks.verify(diskStart: first, diskLength: 2 << 20, from: first + (1 << 20) - 64, count: 65)
            Issue.record("a read one byte into the changed piece verified")
        } catch {
            guard case .checksum = error else {
                Issue.record("\(error)")
                return
            }
        }
    }

    /// A read must lie inside its extent and hold at least a byte; at its very end is inside.
    @Test func aVerifiedReadLiesInsideItsExtent() throws {
        let (fileSystem, _, first) = try Self.randomFile(try ImageOracle.image("btrfs"))
        let checks = fileSystem.dataChecksums
        for (from, count) in [(first, UInt64(0)), (first - 1, 1), (first + (2 << 20) - 1, 2)] {
            do {
                try checks.verify(diskStart: first, diskLength: 2 << 20, from: from, count: count)
                Issue.record("\(from - first + 1) - 1, \(count): verified")
            } catch {
                guard case .corrupt = error else {
                    Issue.record("\(error)")
                    continue
                }
            }
        }
        try checks.verify(diskStart: first, diskLength: 2 << 20, from: first + (2 << 20) - 1, count: 1)
    }
}
