import CFSKernels
import FSCore
import Testing

// The arm64 kernels against the portable C reference (kernels_portable.c), which is compiled on
// every target under the fsk_ref_ names. Lengths cover every tail shape and both fold tiers
// (768 and 3072 bytes); misaligned starts cover the unaligned loads.
@_silgen_name("fsk_ref_crc32c_update")
func referenceCRC(_ crc: UInt32, _ bytes: UnsafePointer<UInt8>?, _ count: Int) -> UInt32
@_silgen_name("fsk_ref_popcount")
func referencePopcount(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> UInt64
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
        let data = random.bytes(9000 + 16)
        for start in [0, 1, 3, 7] {
            for length in Array(0 ... 1100) + [2047, 2048, 3071, 3072, 3073, 4064, 4096, 6144, 7000, 9000] {
                let slice = data[start ..< (start + length)]
                let seed = UInt32(truncatingIfNeeded: random.next())
                let expected = slice.withUnsafeBufferPointer { referenceCRC(seed, $0.baseAddress, $0.count) }
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
            let expected = data.withUnsafeBufferPointer { referencePopcount($0.baseAddress, $0.count) }
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
