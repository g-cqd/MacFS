import CFSKernels
import CFSKernelsBaseline
import Foundation

// AEMI-style comparison: every variant on the same buffers, in one process, nine runs, median and spread.
//   swift run -c release fskbench
// Each result is checked against the reference before it is timed, so a fast wrong kernel shows as FAIL.

func measure(_ name: String, bytes: Int, runs: Int = 9, _ body: () -> UInt64) {
    var times: [Double] = []
    var sink: UInt64 = 0
    for _ in 0 ..< runs {
        let start = DispatchTime.now().uptimeNanoseconds
        sink &+= body()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start))
    }
    times.sort()
    let median = times[runs / 2]
    let gbps = Double(bytes) / median
    print(
        String(
            format: "%-34@ %8.2f GB/s   (%.2f to %.2f)  [%llu]", name as NSString, gbps,
            Double(bytes) / times[runs - 1], Double(bytes) / times[0], sink & 1))
}

let size = 64 << 20
var generator = SystemRandomNumberGenerator()
let data = (0 ..< size).map { _ in UInt8.random(in: 0 ... 255, using: &generator) }
let ascii = (0 ..< (size / 2)).flatMap { _ in [UInt8.random(in: 0x20 ... 0x7E, using: &generator), 0] }
var narrowed = [UInt8](repeating: 0, count: size / 2)

data.withUnsafeBufferPointer { buffer in
    let p = buffer.baseAddress!
    let reference = fsk_crc32c_update(~0, p, size)
    precondition(
        base_crc32c_serial(~0, p, size) == reference && base_crc32c_threeway(~0, p, size) == reference, "CRC mismatch")
    print("CRC-32C, 64 MiB")
    measure("  C, one __crc32cd stream", bytes: size) { UInt64(base_crc32c_serial(~0, p, size)) }
    measure("  C, three streams + vmull_p64", bytes: size) { UInt64(base_crc32c_threeway(~0, p, size)) }
    measure("  C, eight-lane fold (intrinsics)", bytes: size) { UInt64(base_crc32c_fold8(~0, p, size)) }
    measure("  asm, eight-lane pmull fold", bytes: size) { UInt64(fsk_crc32c_update(~0, p, size)) }
    for block in [4096, 16384] {
        let blocks = size / block
        print("CRC-32C, \(blocks) blocks of \(block) bytes (Btrfs data and node checksums)")
        measure("  C, one stream", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< blocks { x &+= UInt64(base_crc32c_serial(~0, p + b * block + 32, block - 32)) }
            return x
        }
        measure("  C, three streams", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< blocks { x &+= UInt64(base_crc32c_threeway(~0, p + b * block + 32, block - 32)) }
            return x
        }
        measure("  C, eight-lane fold", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< blocks { x &+= UInt64(base_crc32c_fold8(~0, p + b * block + 32, block - 32)) }
            return x
        }
        measure("  asm", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< blocks { x &+= UInt64(fsk_crc32c_update(~0, p + b * block + 32, block - 32)) }
            return x
        }
    }
    precondition(base_popcount(p, size) == fsk_popcount(p, size), "popcount mismatch")
    print("Bit count, 64 MiB (NTFS $Bitmap)")
    measure("  C, __builtin_popcountll", bytes: size) { base_popcount(p, size) }
    measure("  asm, cnt + uaddlv", bytes: size) { fsk_popcount(p, size) }
}
ascii.withUnsafeBufferPointer { source in
    narrowed.withUnsafeMutableBufferPointer { target in
        let units = size / 2
        precondition(base_utf16le_ascii_prefix(source.baseAddress!, units, target.baseAddress!) == units)
        print("UTF-16LE to ASCII, \(units) units")
        measure("  C, loop", bytes: size) {
            UInt64(base_utf16le_ascii_prefix(source.baseAddress!, units, target.baseAddress!))
        }
        measure("  asm, umaxv + xtn", bytes: size) {
            UInt64(fsk_utf16le_ascii_prefix(source.baseAddress!, units, target.baseAddress!))
        }
    }
}
