import AemiTestKit
import CFSKernels
import FSCore
import Testing

@testable import Btrfs

@_silgen_name("fsk_ref_lzo1x_decompress")
func referenceLZO1X(
    _ source: UnsafePointer<UInt8>, _ count: Int, _ target: UnsafeMutablePointer<UInt8>, _ capacity: Int
) -> Int64

/// The arm64 LZO1X kernel against the portable C one: the same result and the same bytes up to it, on every liblzo2 stream
/// (TestImages/lzo), those streams damaged or given too little room, and arbitrary bytes.
@Suite struct LZO1XKernelTests {
    static func expectSame(_ input: [UInt8], capacity: Int, _ what: @autoclosure () -> String) {
        guard !input.isEmpty else { return }
        var kernel = [UInt8](repeating: 0xEE, count: capacity + 1)
        var reference = [UInt8](repeating: 0xDD, count: capacity + 1)
        let (k, r) = input.withUnsafeBufferPointer { source in
            (
                kernel.withUnsafeMutableBufferPointer {
                    fsk_lzo1x_decompress(source.baseAddress!, input.count, $0.baseAddress!, capacity)
                },
                reference.withUnsafeMutableBufferPointer {
                    referenceLZO1X(source.baseAddress!, input.count, $0.baseAddress!, capacity)
                }
            )
        }
        #expect(k == r, "\(what()): result")
        if k == r, k > 0 { #expect(kernel[..<Int(k)] == reference[..<Int(k)], "\(what()): bytes") }
        #expect(kernel[capacity] == 0xEE, "\(what()): a write past the capacity")
    }

    @Test(arguments: LZO1XTests.streams)
    func everyLiblzoStreamDecodesTheSame(_ name: String) throws {
        let stream = try LZO1XTests.bytes("\(name).lzo")
        let size = try LZO1XTests.bytes("\(name).raw").count
        Self.expectSame(stream, capacity: size, name)
        Self.expectSame(stream, capacity: size + 100, "\(name), room to spare")
    }

    @Test func damagedStreamsFailOrDecodeTheSame() throws {
        var random = SplitMix(state: 21)
        for name in LZO1XTests.streams.prefix(40) {
            let stream = try LZO1XTests.bytes("\(name).lzo")
            let size = try LZO1XTests.bytes("\(name).raw").count
            for trial in 0 ..< 50 {
                var damaged = stream
                switch trial % 4 {
                    case 0:
                        damaged[Int(random.next() % UInt64(stream.count))] ^= UInt8(
                            truncatingIfNeeded: random.next() | 1)
                    case 1:
                        damaged[Int(random.next() % UInt64(stream.count))] = UInt8(truncatingIfNeeded: random.next())
                    case 2: damaged = Array(stream.prefix(1 + Int(random.next() % UInt64(stream.count))))
                    default: break
                }
                let capacity = trial % 4 == 3 ? Int(random.next() % UInt64(max(1, size))) : size
                Self.expectSame(damaged, capacity: capacity, "\(name), trial \(trial)")
            }
        }
    }

    /// The same, with input and output each flush against an inaccessible page: a read past the stream or a write past the
    /// capacity crashes. Damaged and cut streams, whose instructions point past the end of the input.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func damagedStreamsStayInsideTheirBuffers(edge: GuardedBytes.Edge) throws {
        var random = SplitMix(state: 23)
        for name in LZO1XTests.streams.prefix(24) {
            let stream = try LZO1XTests.bytes("\(name).lzo")
            let size = try LZO1XTests.bytes("\(name).raw").count
            for trial in 0 ..< 30 {
                var damaged = stream
                if trial % 2 == 0 {
                    damaged = Array(stream.prefix(1 + Int(random.next() % UInt64(stream.count))))
                } else {
                    damaged[Int(random.next() % UInt64(stream.count))] = UInt8(truncatingIfNeeded: random.next())
                }
                Self.expectGuarded(damaged, capacity: size, edge: edge, "\(name), trial \(trial)")
            }
        }
    }

    static func expectGuarded(
        _ input: [UInt8], capacity: Int, edge: GuardedBytes.Edge, _ what: @autoclosure () -> String
    ) {
        var reference = [UInt8](repeating: 0, count: max(1, capacity))
        let expected = input.withUnsafeBufferPointer { source in
            reference.withUnsafeMutableBufferPointer {
                referenceLZO1X(source.baseAddress!, input.count, $0.baseAddress!, capacity)
            }
        }
        GuardedBytes.with(input, against: edge) { source in
            GuardedBytes.with([UInt8](repeating: 0xEE, count: max(1, capacity)), against: edge) { target in
                let result = fsk_lzo1x_decompress(source, input.count, target, capacity)
                #expect(result == expected, "\(what())")
                if result == expected, result > 0 {
                    #expect(
                        Array(UnsafeBufferPointer(start: target, count: Int(result)))
                            == Array(reference[..<Int(result)]))
                }
            }
        }
    }

    /// A stream of `literals`, then M2 matches (3 to 8 bytes, `distance` back, each followed by `following` literals), then
    /// the end marker; and what it decodes to.
    static func m2Stream(literals: Int, distance: Int, counts: [Int], following: Int) -> (
        stream: [UInt8], output: [UInt8]
    ) {
        var output = (0 ..< literals).map { UInt8(0x30 + $0 % 64) }
        var stream = [UInt8(17 + literals)] + output
        for (index, count) in counts.enumerated() {
            stream += [UInt8((count - 1) << 5 | ((distance - 1) & 7) << 2 | following), UInt8((distance - 1) >> 3)]
            for _ in 0 ..< count { output.append(output[output.count - distance]) }
            let extra = (0 ..< following).map { UInt8(0x61 + (index + $0) % 26) }
            stream += extra
            output += extra
        }
        return (stream + [0x11, 0, 0], output)
    }

    /// M2 matches at every distance up to 20, with 0 to 3 literals after each, the stream's output ending exactly at the
    /// capacity against a guard page: the inline M2's 8- and 4-byte moves near the end, and below 8 back.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func m2MatchesAtEveryDistanceToTheLastByte(edge: GuardedBytes.Edge) {
        for distance in 1 ... 20 {
            for following in 0 ... 3 {
                for tail in 3 ... 8 {
                    let counts = Array(repeating: 8, count: 6) + [5, tail]
                    let (stream, output) = Self.m2Stream(
                        literals: 24, distance: distance, counts: counts, following: following)
                    Self.expectGuarded(
                        stream, capacity: output.count, edge: edge, "distance \(distance), \(following), \(tail)")
                    let decoded = try? LZO1X.decompress(stream, capacity: output.count)
                    #expect(decoded == output, "distance \(distance), following \(following), tail \(tail)")
                    // Too little room while instructions remain: the moves of the M2 that still fits must stop at the
                    // capacity, and the next one is refused.
                    for short in 1 ... 12 where distance >= 8 {
                        Self.expectGuarded(
                            stream, capacity: output.count - short, edge: edge, "\(distance), \(following), -\(short)")
                    }
                }
            }
        }
    }

    /// After a first literal run of 4 or more, an instruction below 16 is a 3-byte match at least 2 KiB back (state 4): with 8
    /// bytes out, it reaches before the start and is refused; read as a 2-byte match it would decode.
    @Test func afterAFirstRunOfFourOrMoreAShortInstructionReachesFar() throws {
        for run in [4, 5, 8] {
            let stream = [UInt8(17 + run)] + (0 ..< run).map { UInt8(0x41 + $0) } + [0x04, 0x00, 0x11, 0x00, 0x00]
            #expect(throws: DiskError.self, "run \(run)") { try LZO1X.decompress(stream, capacity: 100) }
            Self.expectSame(stream, capacity: 100, "run \(run)")
        }
        // After a first run of 1 to 3, it is a 2-byte match: [A B C] then 2 back for 2, then the end.
        let short: [UInt8] = [20, 0x41, 0x42, 0x43, 0x04, 0x00, 0x11, 0x00, 0x00]
        #expect(try LZO1X.decompress(short, capacity: 100) == [0x41, 0x42, 0x43, 0x42, 0x43])
    }

    @Test func arbitraryBytesDecodeTheSame() {
        var random = SplitMix(state: 22)
        for trial in 0 ..< 3_000 {
            let bytes = random.bytes(1 + Int(random.next() % 600))
            Self.expectSame(bytes, capacity: [4096, 64, 1, 0, 9000][trial % 5], "trial \(trial)")
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
