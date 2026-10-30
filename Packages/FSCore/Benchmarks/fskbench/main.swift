import AemiKernels
import CFSKernelsBaseline
import Foundation

// AEMI-style comparison: every variant on the same buffers, in one process, nine runs, median and spread. "asm" is MacFS's
// former assembly (Benchmarks/CFSKernelsBaseline/kernels_asm.S); "aemi" is what FSCore uses (ADR-0012).
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
    let reference = base_crc32c_asm(~0, p, size)
    precondition(
        base_crc32c_serial(~0, p, size) == reference && base_crc32c_threeway(~0, p, size) == reference, "CRC mismatch")
    print("CRC-32C, 64 MiB")
    measure("  C, one __crc32cd stream", bytes: size) { UInt64(base_crc32c_serial(~0, p, size)) }
    measure("  C, three streams + vmull_p64", bytes: size) { UInt64(base_crc32c_threeway(~0, p, size)) }
    measure("  C, eight-lane fold (intrinsics)", bytes: size) { UInt64(base_crc32c_fold8(~0, p, size)) }
    measure("  asm, eight-lane pmull fold", bytes: size) { UInt64(base_crc32c_asm(~0, p, size)) }
    precondition(AemiKernels.crc32c(~0, p, count: size) == reference, "aemi CRC mismatch")
    measure("  aemi, hybrid from 4 KiB", bytes: size) { UInt64(AemiKernels.crc32c(~0, p, count: size)) }
    print("CRC-32C, one 4 KiB and one 64 KiB block, in cache")
    measure("  asm, 4 KiB", bytes: size) {
        var x: UInt64 = 0
        for _ in 0 ..< size / 4096 { x &+= UInt64(base_crc32c_asm(~0, p, 4096)) }
        return x
    }
    measure("  aemi, 4 KiB", bytes: size) {
        var x: UInt64 = 0
        for _ in 0 ..< size / 4096 { x &+= UInt64(AemiKernels.crc32c(~0, p, count: 4096)) }
        return x
    }
    measure("  asm, 64 KiB", bytes: size) {
        var x: UInt64 = 0
        for _ in 0 ..< size / 65536 { x &+= UInt64(base_crc32c_asm(~0, p, 65536)) }
        return x
    }
    measure("  aemi, 64 KiB", bytes: size) {
        var x: UInt64 = 0
        for _ in 0 ..< size / 65536 { x &+= UInt64(AemiKernels.crc32c(~0, p, count: 65536)) }
        return x
    }
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
            for b in 0 ..< blocks { x &+= UInt64(base_crc32c_asm(~0, p + b * block + 32, block - 32)) }
            return x
        }
        measure("  aemi", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< blocks { x &+= UInt64(AemiKernels.crc32c(~0, p + b * block + 32, count: block - 32)) }
            return x
        }
    }
    // Btrfs name hashes and ext4 metadata checksums: names of a few bytes, inodes of 256, group descriptors of 64.
    for piece in [12, 64, 256] {
        let pieces = size / piece
        precondition(AemiKernels.crc32c(~1, p, count: piece) == base_crc32c_asm(~1, p, piece), "short CRC mismatch")
        print("CRC-32C, \(pieces) pieces of \(piece) bytes")
        measure("  asm", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< pieces { x &+= UInt64(base_crc32c_asm(~1, p + b * piece, piece)) }
            return x
        }
        measure("  aemi", bytes: size) {
            var x: UInt64 = 0
            for b in 0 ..< pieces { x &+= UInt64(AemiKernels.crc32c(~1, p + b * piece, count: piece)) }
            return x
        }
    }
    precondition(base_popcount(p, size) == base_popcount_asm(p, size), "popcount mismatch")
    print("Bit count, 64 MiB (NTFS $Bitmap)")
    measure("  C, __builtin_popcountll", bytes: size) { base_popcount(p, size) }
    measure("  asm, cnt + uaddlv", bytes: size) { base_popcount_asm(p, size) }
    precondition(UInt64(AemiKernels.bitCount(p, count: size)) == base_popcount_asm(p, size), "aemi popcount mismatch")
    measure("  aemi, cnt + uadalp", bytes: size) { UInt64(AemiKernels.bitCount(p, count: size)) }
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
            UInt64(base_utf16le_ascii_prefix_asm(source.baseAddress!, units, target.baseAddress!))
        }
        measure("  aemi, umaxv + xtn", bytes: size) {
            UInt64(AemiKernels.asciiPrefix(utf16LE: source.baseAddress!, units: units, into: target.baseAddress!))
        }
        // The same run with the target moved by a quarter page: shows whether a gap is the kernel or 4 KiB aliasing between
        // the source and target streams.
        let shifted = UnsafeMutablePointer<UInt8>.allocate(capacity: units + 4096)
        defer { shifted.deallocate() }
        measure("  asm, target + 1 KiB", bytes: size) {
            UInt64(base_utf16le_ascii_prefix_asm(source.baseAddress!, units, shifted + 1024))
        }
        measure("  aemi, target + 1 KiB", bytes: size) {
            UInt64(AemiKernels.asciiPrefix(utf16LE: source.baseAddress!, units: units, into: shifted + 1024))
        }
        // NTFS names: most are 8 to 30 units.
        for name in [12, 30] {
            let names = units / name
            print("UTF-16LE to ASCII, \(names) names of \(name) units")
            measure("  asm", bytes: size) {
                var x: UInt64 = 0
                for n in 0 ..< names {
                    let units = source.baseAddress! + 2 * n * name
                    x &+= UInt64(base_utf16le_ascii_prefix_asm(units, name, target.baseAddress!))
                }
                return x
            }
            measure("  aemi", bytes: size) {
                var x: UInt64 = 0
                for n in 0 ..< names {
                    x &+= UInt64(
                        AemiKernels.asciiPrefix(
                            utf16LE: source.baseAddress! + 2 * n * name, units: name, into: target.baseAddress!))
                }
                return x
            }
        }
    }
}
