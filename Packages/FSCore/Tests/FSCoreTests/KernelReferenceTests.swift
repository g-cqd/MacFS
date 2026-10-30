import CFSKernels
import FSCore
import Testing

// FSCore's kernel wrappers against independent references: bitwise CRC-32C and `nonzeroBitCount` here, and for the NTFS
// fixups (the one kernel MacFS keeps in assembly) the portable C version compiled on every target as fsk_ref_. The CRC lengths
// cover every tail, the 256-byte fold and the 4 KiB chunks of aemi's kernel (ADR-0012); misaligned starts cover unaligned loads.
func referenceCRC(_ crc: UInt32, _ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc = crc
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0 ..< 8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x82F6_3B78 : 0) }
    }
    return crc
}
@_silgen_name("fsk_ref_ntfs_apply_fixups")
func referenceFixups(_ record: UnsafeMutablePointer<UInt8>, _ size: Int, _ stride: Int) -> Int32

struct SplitMix {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func bytes(_ count: Int) -> [UInt8] { (0 ..< count).map { _ in UInt8(truncatingIfNeeded: next()) } }
}

@Suite struct KernelReferenceTests {
    @Test func crcMatchesTheReferenceAtEveryLengthAndOffset() {
        var random = SplitMix(state: 1)
        let data = random.bytes(16_384 + 16)
        for start in [0, 1, 3, 7] {
            for length in Array(0 ... 600) + [1023, 2047, 4064, 4095, 4096, 4097, 8192, 8448, 12_301, 16_352, 16_384] {
                let slice = data[start ..< (start + length)]
                let seed = UInt32(truncatingIfNeeded: random.next())
                let expected = referenceCRC(seed, slice)
                #expect(CRC32C.update(seed, slice) == expected, "length \(length) at offset \(start)")
            }
        }
    }

    @Test func crcKnownVector() {
        // RFC 3720 B.4: 32 bytes of zeros give 0x8A9136AA.
        #expect(CRC32C.checksum([UInt8](repeating: 0, count: 32)[...]) == 0x8A91_36AA)
        #expect(CRC32C.checksum(Array("123456789".utf8)[...]) == 0xE306_9283)
    }

    @Test func popcountMatchesTheReference() {
        var random = SplitMix(state: 2)
        for length in Array(0 ... 200) + [1023, 1024, 65_537] {
            let data = random.bytes(length)
            let expected = UInt64(data.reduce(0) { $0 + $1.nonzeroBitCount })
            #expect(BitCount.ones(in: data) == expected, "length \(length)")
        }
    }

    @Test func utf16AsciiAndNonAscii() throws {
        for name in ["", "a", "hello.txt", "exactly8", "longer than sixteen units", "café", "日本語.txt", "abcdefgh€"] {
            var raw: [UInt8] = []
            for unit in name.utf16 { raw += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            #expect(UTF16Name.utf8(DiskBytes(raw)) == Array(name.utf8), "\(name)")
        }
    }

    @Test func fixupsAgreeWithTheReferenceOnRandomRecords() {
        var random = SplitMix(state: 3)
        for trial in 0 ..< 2000 {
            var record = random.bytes(1024)
            // A plausible header most of the time, garbage some of the time.
            if trial % 4 != 0 {
                record[4] = 0x30
                record[5] = 0
                record[6] = 3
                record[7] = 0
                if trial % 3 != 0 {
                    record[510] = record[0x30]
                    record[511] = record[0x31]
                    record[1022] = record[0x30]
                    record[1023] = record[0x31]
                }
            }
            var copy = record
            let expected = copy.withUnsafeMutableBufferPointer { referenceFixups($0.baseAddress!, 1024, 512) }
            var mine = record
            let status: Int32
            do {
                try UpdateSequence.apply(&mine, what: "test")
                status = 0
            } catch {
                status = error == .corrupt("test: torn write (update sequence mismatch)") ? -2 : -1
            }
            #expect(status == expected, "trial \(trial)")
            if status == 0 { #expect(mine == copy) }
        }
    }
}
