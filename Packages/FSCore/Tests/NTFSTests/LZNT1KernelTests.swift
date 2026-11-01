import CFSKernels
import FSCore
import Testing

@testable import NTFS

@_silgen_name("fsk_ref_lznt1_decompress")
func referenceLZNT1(
    _ source: UnsafePointer<UInt8>,
    _ count: Int,
    _ target: UnsafeMutablePointer<UInt8>,
    _ capacity: Int
) -> Int32

/// The arm64 LZNT1 kernel against the portable C one, byte for byte and status for status: on every compressed unit of the
/// ntfs-lznt1 image (ntfs-3g's compressor), on those units damaged, and on arbitrary bytes. The C one is the byte-wise
/// decoder the hand-built LZNT1Tests and the images pinned first.
@Suite struct LZNT1KernelTests {
    static func both(_ input: [UInt8], capacity: Int) -> (kernel: (Int32, [UInt8]), reference: (Int32, [UInt8])) {
        var kernel = [UInt8](repeating: 0xEE, count: capacity)
        var reference = [UInt8](repeating: 0xDD, count: capacity)
        let padded = input.isEmpty ? [0] : input
        let (k, r) = padded.withUnsafeBufferPointer { source in
            let k = kernel.withUnsafeMutableBufferPointer {
                fsk_lznt1_decompress(source.baseAddress!, input.count, $0.baseAddress!, capacity)
            }
            let r = reference.withUnsafeMutableBufferPointer {
                referenceLZNT1(source.baseAddress!, input.count, $0.baseAddress!, capacity)
            }
            return (k, r)
        }
        return ((k, kernel), (r, reference))
    }

    static func expectSame(_ input: [UInt8], capacity: Int, _ what: @autoclosure () -> String) {
        let (kernel, reference) = both(input, capacity: capacity)
        #expect(kernel.0 == reference.0, "\(what()): status")
        if kernel.0 == 0, reference.0 == 0 { #expect(kernel.1 == reference.1, "\(what()): bytes") }
    }

    /// Every unit of every compressed file in the image that holds LZNT1 chunks (some clusters allocated, not all).
    static func realUnits() throws -> [[UInt8]] {
        let source = try ImageOracle.image("ntfs-lznt1")
        let fileSystem = try NTFSFileSystem(source: source)
        var units: [[UInt8]] = []
        var pending = [fileSystem.rootID]
        while let directory = pending.popLast() {
            for entry in try fileSystem.entries(of: directory, from: 0, limit: 10_000) {
                if entry.kind == .directory { pending.append(entry.id) }
                guard entry.kind == .regular else { continue }
                let record = try fileSystem.record(entry.id)
                let stream = try NTFSStream(
                    record.extents(NTFSAttributeType.data),
                    clusterSize: fileSystem.boot.clusterSize
                )
                guard let clusters = stream.compressionUnitClusters else { continue }
                let unitBytes = UInt64(clusters * fileSystem.boot.clusterSize)
                for unit in 0 ..< (stream.size + unitBytes - 1) / unitBytes {
                    let parts = try stream.parts(of: unit, clusters: clusters)
                    let allocated = parts.reduce(0) { $0 + ($1.cluster == nil ? 0 : $1.length) }
                    if allocated > 0, allocated < UInt64(clusters) { units.append(try stream.stored(source, parts)) }
                }
            }
        }
        return units
    }

    @Test func everyRealUnitDecodesTheSame() throws {
        let units = try Self.realUnits()
        #expect(units.count >= 20, "the image should hold compressed units")
        for (index, unit) in units.enumerated() {
            let (kernel, reference) = Self.both(unit, capacity: 65_536)
            #expect(kernel.0 == 0 && reference.0 == 0, "unit \(index)")
            #expect(kernel.1 == reference.1, "unit \(index)")
        }
    }

    /// Real units with a byte changed, cut short, or decoded into less room than a unit.
    @Test func damagedUnitsFailOrDecodeTheSame() throws {
        var random = SplitMix(state: 14)
        for (index, unit) in try Self.realUnits().prefix(40).enumerated() {
            for trial in 0 ..< 60 {
                var damaged = unit
                switch trial % 3 {
                    case 0:
                        damaged[Int(random.next() % UInt64(unit.count))] ^= UInt8(truncatingIfNeeded: random.next() | 1)
                    case 1: damaged = Array(unit.prefix(Int(random.next() % UInt64(unit.count))))
                    default: break
                }
                let capacity = trial % 3 == 2 ? Int(random.next() % 65_536) : 65_536
                Self.expectSame(damaged, capacity: capacity, "unit \(index), trial \(trial)")
            }
        }
    }

    /// Arbitrary bytes behind a compressed chunk's header, at every size up to a few chunks.
    @Test func arbitraryBytesDecodeTheSame() {
        var random = SplitMix(state: 15)
        for trial in 0 ..< 3_000 {
            var bytes = random.bytes(Int(random.next() % 9_000))
            // Mostly compressed chunks; every fourth a stored one, of any size near 4 KiB.
            if bytes.count >= 2 { bytes[1] = (bytes[1] & 0x0F) | (trial % 4 == 0 ? 0x30 : 0xB0) }
            if trial % 4 == 0, bytes.count >= 2 {
                let size = 4096 + Int(random.next() % 9) - 4
                bytes[0] = UInt8((size - 1) & 0xFF)
                bytes[1] = 0x30 | UInt8((size - 1) >> 8)
            }
            Self.expectSame(bytes, capacity: [65_536, 8192, 4096, 5000, 0][trial % 5], "trial \(trial)")
        }
    }

    /// Phrases 8 to 15 back and longer than their distance, among literals, with input and room enough for the kernel's fast
    /// groups: each repeats bytes it is itself writing, which a single 16-byte move would read before they are written.
    @Test func overlappingPhrasesInsideFastGroups() {
        for distance in 8 ... 15 {
            for length in distance + 1 ... 16 {
                var data: [UInt8] = []
                for group in 0 ..< 3 { data += [0x00] + (0 ..< 8).map { UInt8(0x61 + 8 * group + $0) } }
                for _ in 0 ..< 6 {
                    // Literal, phrase, literal, phrase... at positions past 24: the split there has moved by one bit.
                    data += [0xAA]
                    for _ in 0 ..< 4 {
                        data += [0x7A]
                        let token = (distance - 1) << 11 | (length - 3)
                        data += [UInt8(token & 0xFF), UInt8(token >> 8)]
                    }
                }
                let field = UInt16(data.count - 1) | 0xB000
                let chunk = [UInt8(field & 0xFF), UInt8(field >> 8)] + data
                Self.expectSame(chunk, capacity: 65_536, "distance \(distance), length \(length)")
            }
        }
    }

    /// Long runs, distances below and above 8, phrases ending at a chunk's last bytes: the kernel's word paths at their edges.
    @Test func builtStreamsAtTheWordPathsEdges() {
        for distance in 1 ... 12 {
            for length in [3, 7, 8, 9, 15, 16, 17, 100, 4096 - distance - 1] {
                var data: [UInt8] = []
                var literals = (0 ..< distance).map { UInt8(0x30 + $0) }
                while !literals.isEmpty {
                    let group = Array(literals.prefix(8))
                    literals.removeFirst(group.count)
                    data += [0x00] + group
                }
                // At position `distance` (< 16 here, bar the long cases) the split may have moved: compute it as the format does.
                var shift = 0
                var reach = distance - 1
                while reach >= 0x10 {
                    shift += 1
                    reach >>= 1
                }
                let fits = length - 3 <= (0x0FFF >> shift)
                guard fits else { continue }
                let token = UInt16((distance - 1) << (12 - shift) | (length - 3))
                data += [0x01, UInt8(token & 0xFF), UInt8(token >> 8)]
                let field = UInt16(data.count + 2 - 3) | 0xB000
                let chunk = [UInt8(field & 0xFF), UInt8(field >> 8)] + data
                Self.expectSame(chunk, capacity: 65_536, "distance \(distance), length \(length)")
                Self.expectSame(chunk + chunk, capacity: 8192, "two chunks, distance \(distance), length \(length)")
            }
        }
    }
}

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
