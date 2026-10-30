import CFSKernels
import KernelABI
import Testing

/// The assembly kernels keep what the Apple arm64 ABI has callers keep: x19-x28, x29, sp and d8-d15, each set before the
/// call to a value of its own and compared after it (fsk_abi_call). A kernel that saves a register and restores another
/// gives every result right and breaks its caller, which result comparisons never show.
@Suite struct KernelABITests {
    /// The registers in `changed` (fsk_abi_call's mask), by name.
    static func names(_ changed: UInt32) -> [String] {
        let all = (19 ... 28).map { "x\($0)" } + ["x29", "sp"] + (8 ... 15).map { "d\($0)" }
        return changed == 0xFFFF_FFFF ? ["not arm64"] : all.indices.filter { changed >> $0 & 1 == 1 }.map { all[$0] }
    }

    /// `function(arguments)` through fsk_abi_call: the registers it changed, and its x0.
    static func call(_ function: UnsafeRawPointer, _ arguments: [UInt64]) -> (changed: [String], result: UInt64) {
        var result: UInt64 = 0
        let padded = arguments + [UInt64](repeating: 0, count: 6 - arguments.count)
        let changed = padded.withUnsafeBufferPointer { fsk_abi_call(function, $0.baseAddress!, &result) }
        return (names(changed), result)
    }

    static func address<T>(_ pointer: UnsafePointer<T>) -> UInt64 { UInt64(UInt(bitPattern: pointer)) }

    #if arch(arm64)
        @Test func theZstdSequenceKernelKeepsTheRegisters() {
            var output = [UInt8](repeating: 0, count: 64)
            var result: Int64 = 0
            #expect(Self.names(fsk_abi_zstd_sequences(1, &output, &result)) == [])
            #expect(result == 0)
            #expect(Array(output[0 ..< 6]) == Array("abcabc".utf8))
            #expect(Self.names(fsk_abi_zstd_sequences(0, &output, &result)) == [])
            #expect(result == -1)
        }

        @Test func theLZO1XKernelKeepsTheRegisters() {
            let lzo: @convention(c) (UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, Int) -> Int64 =
                fsk_lzo1x_decompress
            // Four literals, then the end marker.
            let stream: [UInt8] = [0x15, 0x61, 0x62, 0x63, 0x64, 0x11, 0, 0]
            var output = [UInt8](repeating: 0, count: 64)
            let (changed, result) = stream.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target in
                    Self.call(
                        unsafeBitCast(lzo, to: UnsafeRawPointer.self),
                        [Self.address(source.baseAddress!), 8, Self.address(target.baseAddress!), 64])
                }
            }
            #expect(changed == [])
            #expect(result == 4)
            #expect(Array(output[0 ..< 4]) == Array("abcd".utf8))
        }

        @Test func theLZNT1KernelKeepsTheRegisters() {
            let lznt1: @convention(c) (UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, Int) -> Int32 =
                fsk_lznt1_decompress
            // One compressed chunk: a flag byte of literals, "abc"; the rest of the unit zero.
            let chunk: [UInt8] = [0x03, 0xB0, 0x00, 0x61, 0x62, 0x63]
            var output = [UInt8](repeating: 0, count: 4096)
            let (changed, result) = chunk.withUnsafeBufferPointer { source in
                output.withUnsafeMutableBufferPointer { target in
                    Self.call(
                        unsafeBitCast(lznt1, to: UnsafeRawPointer.self),
                        [Self.address(source.baseAddress!), 6, Self.address(target.baseAddress!), 4096])
                }
            }
            #expect(changed == [])
            #expect(Int32(truncatingIfNeeded: result) == 0)
            #expect(Array(output[0 ..< 4]) == Array("abc".utf8) + [0])
        }

        @Test func theFixupsKernelKeepsTheRegisters() {
            let fixups: @convention(c) (UnsafeMutablePointer<UInt8>, Int, Int) -> Int32 = fsk_ntfs_apply_fixups
            // A 1024-byte record of two 512-byte strides: the array at 8 (sequence number 7, then the two saved words),
            // each stride ending with the sequence number.
            var record = [UInt8](repeating: 0, count: 1024)
            record[4] = 8
            record[6] = 3
            record[8 ..< 14] = [7, 0, 0xAA, 0xBB, 0xCC, 0xDD]
            record[510 ..< 512] = [7, 0]
            record[1022 ..< 1024] = [7, 0]
            let (changed, result) = record.withUnsafeMutableBufferPointer { base in
                Self.call(
                    unsafeBitCast(fixups, to: UnsafeRawPointer.self), [Self.address(base.baseAddress!), 1024, 512])
            }
            #expect(changed == [])
            #expect(Int32(truncatingIfNeeded: result) == 0)
            #expect(Array(record[510 ..< 512] + record[1022 ..< 1024]) == [0xAA, 0xBB, 0xCC, 0xDD])
        }
    #endif

    /// The check itself: a function that changes x25 and d9 is caught (otherwise every test above would pass vacuously).
    @Test func theCheckCatchesAChangedRegister() {
        #if arch(arm64)
            #expect(Self.names(fsk_abi_clobber_for_test()) == ["x25", "d9"])
        #endif
    }
}
