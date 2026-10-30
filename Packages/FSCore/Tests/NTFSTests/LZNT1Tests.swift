import FSCore
import Testing

@testable import NTFS

/// LZNT1 ([MS-XCA] 2.5; ntfs-3g's `ntfs_decompress`), on hand-built chunks for each rule. The images hold the reference
/// compressor's output (ntfs-3g), read back by ntfs-3g (NTFSConformanceTests).
@Suite struct LZNT1Tests {
    static let unit = 65_536

    /// A compressed chunk: its header (signature 3, the compressed bit, size - 3) and its data.
    static func chunk(_ data: [UInt8]) -> [UInt8] {
        let field = UInt16(data.count + 2 - 3) | 0xB000
        return [UInt8(field & 0xFF), UInt8(field >> 8)] + data
    }

    @Test func aStoredChunkIsCopied() throws {
        let raw = (0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let output = try LZNT1.decompress([0xFF, 0x3F] + raw, capacity: Self.unit)
        #expect(Array(output[0 ..< 4096]) == raw)
        #expect(output.count == Self.unit && output[4096...].allSatisfy { $0 == 0 }, "the rest of the unit is zero")
    }

    @Test func literalsAndAnOverlappingPhrase() throws {
        // Three literals, then a phrase 3 back for 9 bytes: at position 3 offsets take 4 bits, lengths 12.
        let output = try LZNT1.decompress(Self.chunk([0x08, 0x61, 0x62, 0x63, 0x06, 0x20]), capacity: Self.unit)
        #expect(Array(output[0 ..< 12]) == Array("abcabcabcabc".utf8))
        #expect(output[12 ..< 4096].allSatisfy { $0 == 0 }, "a short chunk is zero-filled to 4 KiB")
    }

    /// Past position 16 the offset takes one more bit and the length one fewer: at 32, five bits of offset, eleven of length.
    @Test func theSplitMovesWithThePosition() throws {
        let literals = (0 ..< 32).map { UInt8(0x41 + $0 % 26) }
        var data: [UInt8] = []
        for group in 0 ..< 4 { data += [0x00] + literals[8 * group ..< 8 * group + 8] }
        // A phrase 32 back (offset field 31 in the top five bits), 3 + 1 = 4 bytes.
        data += [0x01, 0x01, 0xF8]
        let output = try LZNT1.decompress(Self.chunk(data), capacity: Self.unit)
        #expect(Array(output[0 ..< 36]) == literals + literals[0 ..< 4])
    }

    @Test func eachChunkDecodesIntoItsOwnFourKiB() throws {
        let first = Self.chunk([0x00, 0x31, 0x32])
        let second = Self.chunk([0x00, 0x33])
        let output = try LZNT1.decompress(first + second + [0, 0], capacity: Self.unit)
        #expect(Array(output[0 ..< 2]) == [0x31, 0x32] && output[4096] == 0x33)
        #expect(output[2 ..< 4096].allSatisfy { $0 == 0 })
    }

    /// A phrase may not reach before its chunk, and a chunk may not overrun its input or its 4 KiB.
    @Test(arguments: [
        ("a phrase first", [UInt8(0x01), 0x00, 0x00]),
        ("a phrase before the chunk", [0x02, 0x61, 0x00, 0x30]),
        ("a phrase past the chunk's 4 KiB", [0x02, 0x61, 0xFF, 0x0F]),
        ("a phrase cut short", [0x02, 0x61, 0x00])
    ])
    func damagedChunksAreErrors(_ what: String, _ data: [UInt8]) {
        #expect(throws: DiskError.self, "\(what)") { try LZNT1.decompress(Self.chunk(data), capacity: Self.unit) }
    }

    /// Chunks are independent: a phrase may not reach back into the chunk before it.
    @Test func aPhraseMayNotReachIntoThePreviousChunk() {
        let first = Self.chunk([0x00, 0x61, 0x62])
        let second = Self.chunk([0x02, 0x63, 0x01, 0x10])  // two back from position 1
        #expect(throws: DiskError.self) { try LZNT1.decompress(first + second, capacity: Self.unit) }
    }

    @Test func aChunkLongerThanItsInputIsAnError() {
        #expect(throws: DiskError.self) { try LZNT1.decompress([0x10, 0xB0, 0x00, 0x41], capacity: Self.unit) }
        #expect(throws: DiskError.self) { try LZNT1.decompress([0xFF, 0x3F, 0x00], capacity: Self.unit) }
    }

    @Test func moreChunksThanTheUnitHoldsIsAnError() {
        let full = [UInt8]([0xFF, 0x3F]) + [UInt8](repeating: 0x55, count: 4096)
        #expect(throws: DiskError.self) {
            try LZNT1.decompress(Array(repeating: full, count: 2).flatMap { $0 }, capacity: 4096 + 100)
        }
    }

    /// Any bytes at all decode or fail: no trap, no hang (seeded).
    @Test func arbitraryBytesNeverTrap() {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0 ..< 2_000 {
            var bytes: [UInt8] = []
            for _ in 0 ..< Int(state % 600) {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                bytes.append(UInt8(truncatingIfNeeded: state >> 33))
            }
            if bytes.count >= 2 { bytes[1] = (bytes[1] & 0x0F) | 0xB0 }
            _ = try? LZNT1.decompress(bytes, capacity: Self.unit)
            state = state &* 6_364_136_223_846_793_005 &+ 1
        }
    }
}
