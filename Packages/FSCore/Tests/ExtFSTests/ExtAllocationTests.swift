import CrashTesting
import FSCore
import Foundation
import Testing

@testable import ExtFS

/// ext2 allocation (roadmap 0026 step 2, ADR-0018): files grow and holes fill, through the block bitmaps, the group
/// descriptors' counts and the indirect blocks. New blocks are written, and flushed, before anything points to them; a crash
/// leaves at worst blocks e2fsck's preen gives back, never a pointer to an unwritten block.
@Suite struct ExtAllocationTests {
    static func open() throws -> (MemoryBlockSource, ExtFileSystem) {
        let device = try ExtWriteTests.copy("ext2")
        return (device, try ExtWriteTests.writable(device))
    }

    static func sectors(_ volume: ExtFileSystem, _ id: UInt64) throws -> UInt64 { try volume.inode(id).sectors }

    static func e2fsck(_ device: MemoryBlockSource) throws {
        guard Checkers.isAvailable else { return }
        let result = try #require(Checkers.run(["e2fsck", "-fn"], on: ["volume": device.bytes])?["volume"])
        #expect(result.status == 0, "\(result.output)")
    }

    @Test func aFileGrowsAndReadsBack() throws {
        let (device, volume) = try Self.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        try volume.write(hello, at: 12, Array("world\n".utf8))
        #expect(try volume.attributes(of: hello).size == 18)
        #expect(try volume.read(hello, at: 0, count: 100) == Array("hello btrfs\nworld\n".utf8))
        try volume.close()
        #expect(try ExtFileSystem(source: device).read(hello, at: 0, count: 100) == Array("hello btrfs\nworld\n".utf8))
        try Self.e2fsck(device)
    }

    /// Past the twelve direct blocks the file needs an indirect block: allocated, filled, then linked.
    @Test func growingPastTheDirectBlocksAllocatesAnIndirectOne() throws {
        let (device, volume) = try Self.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let payload = (0 ..< 20_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        try volume.write(hello, at: 0, payload)
        // 20 data blocks of 1 KiB and one indirect block, in 512-byte sectors.
        #expect(try Self.sectors(volume, hello) == 21 * 2)
        try volume.close()
        #expect(try ExtFileSystem(source: device).read(hello, at: 0, count: 30_000) == payload)
        try Self.e2fsck(device)
    }

    @Test func aHoleIsFilledAndTheRestOfItStaysAHole() throws {
        let (device, volume) = try Self.open()
        let sparse = try ExtHtreeTests.path(volume, "big/sparse.bin")
        let before = try Self.sectors(volume, sparse)
        try volume.write(sparse, at: 4096, [1, 2, 3])
        #expect(try Self.sectors(volume, sparse) == before + 2)
        try volume.close()
        let read = try ExtFileSystem(source: device).read(sparse, at: 0, count: 8192)
        var expected = [UInt8](repeating: 0, count: 8192)
        expected.replaceSubrange(4096 ..< 4099, with: [1, 2, 3])
        #expect(read == expected)
        try Self.e2fsck(device)
    }

    /// A write far past the end: the bytes between read as zeros (even where the old last block held bytes past the old end),
    /// and only the written blocks are allocated.
    @Test func aWriteFarPastTheEndLeavesAHole() throws {
        let (device, volume) = try Self.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let block = try #require(try volume.runs(try volume.inode(hello)).first?.physical)
        try device.write(at: block * 1024 + 12, [UInt8](repeating: 0xEE, count: 1012))
        try volume.write(hello, at: 100_000, [9])
        #expect(try volume.attributes(of: hello).size == 100_001)
        let read = try volume.read(hello, at: 0, count: 100_001)
        #expect(Array(read[0 ..< 12]) == Array("hello btrfs\n".utf8))
        #expect(read[12 ..< 100_000].allSatisfy { $0 == 0 })
        #expect(read[100_000] == 9)
        // The first block, the new last block and the indirect block that maps it.
        #expect(try Self.sectors(volume, hello) == 3 * 2)
        try volume.close()
        try Self.e2fsck(device)
    }

    /// Growing a file already mapped through a double indirect block adds a pointer to its existing second-level block, which
    /// keeps every pointer it had.
    @Test func growingADoubleIndirectFileKeepsItsBlocks() throws {
        let (device, volume) = try Self.open()
        let random = try ExtHtreeTests.path(volume, "big/random.bin")
        let size = try volume.attributes(of: random).size
        let before = try volume.read(random, at: 0, count: Int(size))
        try volume.write(random, at: size, [UInt8](repeating: 0x5A, count: 1024))
        try volume.close()
        let after = try ExtFileSystem(source: device).read(random, at: 0, count: Int(size) + 2048)
        #expect(after == before + [UInt8](repeating: 0x5A, count: 1024))
        try Self.e2fsck(device)
    }

    /// A group whose count says full is passed over, even if its bitmap shows free bits (its count would go below zero): the
    /// search goes on to the next group, wrapping at the end.
    @Test func aFullGroupIsPassedOver() throws {
        let device = try ExtWriteTests.copy("ext2")
        let reader = try ExtFileSystem(source: device)
        let superblock = reader.superblock
        // Group 7, the last: its descriptor's free count 0, its bitmap left as it is.
        let descriptor = superblock.descriptors.descriptorBlock(0) * 1024 + 7 * 32
        try device.write(at: descriptor + 0x0C, [0, 0])
        var allocation = ExtAllocation(
            superblock: superblock,
            device: device,
            free: ExtFreeCounts(blocks: superblock.freeBlocks, inodes: superblock.freeInodes),
            pointers: [UInt32](repeating: 0, count: 15),
            goal: superblock.firstDataBlock + 7 * UInt64(superblock.blocksPerGroup)
        )
        let block = try allocation.allocate()
        #expect(
            block < superblock.firstDataBlock + 7 * UInt64(superblock.blocksPerGroup),
            "wrapped past the full group"
        )
    }

    @Test func theFreeCountsFollowTheAllocation() throws {
        let (device, volume) = try Self.open()
        let free = try volume.statistics().freeBlocks
        try volume.write(try ExtHtreeTests.path(volume, "hello.txt"), at: 0, [UInt8](repeating: 1, count: 20_000))
        // What df sees while the volume is mounted, and what the superblock says after.
        #expect(try volume.statistics().freeBlocks == free - 20)
        try volume.close()
        #expect(try ExtFileSystem(source: device).statistics().freeBlocks == free - 20)
        try Self.e2fsck(device)
    }

    /// More than the volume holds: refused before anything is written.
    @Test func aWriteLargerThanTheFreeSpaceSaysNoSpace() throws {
        let (device, volume) = try Self.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let before = device.bytes
        #expect(throws: DiskError.noSpace) { try volume.write(hello, at: 0, [UInt8](repeating: 1, count: 70 << 20)) }
        #expect(device.bytes == before)
        #expect(DiskError.noSpace.posixCode == ENOSPC)
    }

    /// Every crash state of a growing write: e2fsck's preen repairs it (leaked blocks at worst), the check after finds
    /// nothing, and the file never shows a new block's old contents: past its old size it reads the new bytes or ends.
    @Test func everyCrashStateOfAGrowingWriteIsRepairableAndExposesNothing() throws {
        let original = try ExtWriteTests.copy("ext2")
        let recorder = CrashRecorder(original)
        let volume = try ExtWriteTests.writable(recorder)
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let payload = (0 ..< 14_000).map { UInt8(truncatingIfNeeded: 1 + $0 % 250) }
        try volume.write(hello, at: 12, payload)
        try volume.close()
        let expected = Array("hello btrfs\n".utf8) + payload
        let states = recorder.crashStates()
        for state in states {
            let reader = try ExtFileSystem(source: state)
            let size = Int(try reader.attributes(of: hello).size)
            #expect(size == 12 || size == expected.count, "\(state.name): size \(size)")
            #expect(try reader.read(hello, at: 0, count: size) == Array(expected.prefix(size)), "\(state.name)")
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
}
