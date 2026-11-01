import CrashTesting
import FSCore
import Foundation
import Testing

@testable import ExtFS

/// Writes the kernel makes itself (roadmap 0046, FSKit's kernel-offloaded I/O): the module maps a range for writing
/// (allocating, zeroing and linking its blocks), the kernel writes the data to the device, the module completes the write
/// (the size, the times). Through FSKit's write handler, writes of 256 KiB and more never reached the module (measured);
/// Apple's own modules write this way.
@Suite struct ExtMappedWriteTests {
    /// The kernel's part: `bytes` written to the device where the map says.
    static func kernelWrites(
        _ bytes: [UInt8],
        at offset: UInt64,
        through map: [MappedRange],
        to device: any WritableBlockSource
    ) throws {
        for range in map {
            let physical = try #require(range.physical, "a range mapped for writing is stored")
            let from = max(offset, range.logical)
            let to = min(offset + UInt64(bytes.count), range.logical + range.length)
            guard from < to else { continue }
            try device.write(
                at: physical + (from - range.logical),
                Array(bytes[Int(from - offset) ..< Int(to - offset)])
            )
        }
    }

    @Test func aRangeMappedForWritingIsStoredAndTheWriteCompletes() async throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let data = (0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }
        let map = try volume.mapForWriting(hello, offset: 0, length: UInt64(data.count))
        #expect(map.allSatisfy { $0.physical != nil })
        #expect(map.reduce(0) { $0 + $1.length } >= UInt64(data.count))
        // Until the write completes, the file keeps its size: what the kernel has not written is not the file's yet.
        #expect(try volume.attributes(of: hello).size == 12)
        try Self.kernelWrites(data, at: 0, through: map, to: device)
        try volume.completeWrite(hello, offset: 0, length: UInt64(data.count))
        #expect(try volume.attributes(of: hello).size == UInt64(data.count))
        #expect(try volume.attributes(of: hello).modified == ExtWriteTests.now)
        #expect(try volume.read(hello, at: 0, count: data.count) == data)
        try volume.close()
        #expect(try ExtFileSystem(source: device).read(hello, at: 0, count: data.count) == data)
        try await ExtNamespaceTests.e2fsck(device)
    }

    /// The new blocks are zeroed before they are linked: a crash before the kernel's write, then e2fsck growing the size to
    /// the blocks, never shows another file's old bytes.
    @Test func newBlocksAreZeroedBeforeTheyAreLinked() throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let map = try volume.mapForWriting(hello, offset: 1024, length: 8192)
        for range in map {
            let physical = try #require(range.physical)
            #expect(try device.read(at: physical, count: Int(range.length)).allSatisfy { $0 == 0 })
        }
    }

    /// Every crash state of a mapped write: preen repairs it, the check after finds nothing, and past its old size the file
    /// reads the new bytes or ends.
    @Test func everyCrashStateOfAMappedWriteIsRepairableAndExposesNothing() async throws {
        let original = try ExtWriteTests.copy("ext2")
        let recorder = CrashRecorder(original)
        let volume = try ExtWriteTests.writable(recorder)
        let hello = try ExtHtreeTests.path(volume, "hello.txt")
        let data = (0 ..< 14_000).map { UInt8(truncatingIfNeeded: 1 + $0 % 250) }
        let map = try volume.mapForWriting(hello, offset: 12, length: UInt64(data.count))
        try Self.kernelWrites(data, at: 12, through: map, to: recorder)
        try volume.completeWrite(hello, offset: 12, length: UInt64(data.count))
        try volume.close()
        let expected = Array("hello btrfs\n".utf8) + data
        let states = recorder.crashStates()
        for state in states {
            let reader = try ExtFileSystem(source: state)
            let size = Int(try reader.attributes(of: hello).size)
            #expect(size == 12 || size == expected.count, "\(state.name): size \(size)")
            #expect(try reader.read(hello, at: 0, count: size) == Array(expected.prefix(size)), "\(state.name)")
        }
        try await ExtRenameTests.expectRepairable(states, by: ["e2fsck", "-fp"])
    }
}
