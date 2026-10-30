import AemiTestKit
import FSCore
import Foundation
import Testing

@testable import Btrfs

/// The LZO1X decoder against liblzo2 (`TestImages/lzo`: streams `lzo1x_1` and `lzo1x_999` wrote, with their originals), and on
/// mutated streams against the decoder it replaced: the same output or the same refusal, never a trap.
@Suite struct LZO1XTests {
    static let directory = ImageOracle.directory.appendingPathComponent("lzo")

    static let streams: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".lzo") }.map { String($0.dropLast(4)) }.sorted()
    }()

    static func bytes(_ name: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: directory.appendingPathComponent(name)))
    }

    @Test func theFixturesAreThere() { #expect(Self.streams.count >= 96, "run the images command") }

    @Test(arguments: streams)
    func everyLiblzoStreamDecodesToItsOriginal(_ name: String) throws {
        let original = try Self.bytes("\(name).raw")
        let stream = try Self.bytes("\(name).lzo")
        #expect(try LZO1X.decompress(stream, capacity: original.count) == original)
        #expect(try LZO1XReference.decompress(stream, capacity: original.count) == original, "the reference decoder")
    }

    /// A stream of `literals`, then a match of `count` bytes from `distance` back, then `run` more literals (a literal
    /// instruction, taken when the match leaves no trailing literals), then the end marker. Built by hand to reach the edges
    /// of the word copies that liblzo's streams may never touch.
    static func stream(literals: [UInt8], distance: Int, count: Int, run: [UInt8] = []) -> (
        stream: [UInt8], output: [UInt8]
    ) {
        precondition(
            literals.count >= 4 && literals.count <= 238 && count >= 3 && count <= 33 && distance <= literals.count)
        var stream = [UInt8(17 + literals.count)] + literals
        stream += [UInt8(32 | (count - 2)), UInt8(((distance - 1) << 2) & 0xFF), UInt8((distance - 1) >> 6)]
        var output = literals
        for _ in 0 ..< count { output.append(output[output.count - distance]) }
        if !run.isEmpty {
            precondition(run.count >= 4 && run.count <= 18)
            stream += [UInt8(run.count - 3)] + run
            output += run
        }
        return (stream + [0x11, 0, 0], output)
    }

    /// Matches whose distance is around the word size (7 must go byte by byte; 8 may take words), with counts that end on,
    /// before and after a word; and literal runs around one word. Each decoded into exactly its size against a guard page.
    @Test func wordCopiesAtTheirEdges() throws {
        let letters = (0 ..< 40).map { UInt8(ascii: "a") + UInt8($0 % 26) }
        for distance in [1, 2, 3, 6, 7, 8, 9, 15, 16, 17] {
            for count in [3, 7, 8, 9, 15, 16, 17, 31, 33] {
                for runLength in [0, 4, 7, 8, 9, 10, 18] {
                    let run = (0 ..< runLength).map { UInt8(ascii: "A") + UInt8($0) }
                    let (stream, expected) = Self.stream(
                        literals: Array(letters.prefix(max(4, distance))), distance: distance, count: count, run: run)
                    #expect(
                        try LZO1X.decompress(stream, capacity: expected.count) == expected,
                        "distance \(distance), count \(count), run \(runLength)")
                    try Self.guardedDecode(stream, size: expected.count, expected: expected)
                }
            }
        }
    }

    /// Input and output flush against inaccessible pages: a word read past the stream, or a word written past the capacity,
    /// crashes the run.
    static func guardedDecode(_ stream: [UInt8], size: Int, expected: [UInt8]) throws {
        let written = try GuardedBytes.with(stream, against: .end) { input in
            try GuardedBytes.with([UInt8](repeating: 0, count: size), against: .end) { output in
                let count = try unsafe LZO1X.decompress(
                    UnsafeBufferPointer(start: input, count: stream.count),
                    into: UnsafeMutableBufferPointer(start: output, count: size))
                return Array(UnsafeBufferPointer(start: output, count: count))
            }
        }
        #expect(written == expected)
    }

    @Test(arguments: streams)
    func everyLiblzoStreamDecodesAgainstGuardPages(_ name: String) throws {
        let original = try Self.bytes("\(name).raw")
        try Self.guardedDecode(try Self.bytes("\(name).lzo"), size: original.count, expected: original)
    }

    /// Flipped, overwritten and truncated streams, and a capacity that is too small: the decoders agree on every one.
    @Test func mutatedStreamsDecodeAsTheReferenceDecodesThem() throws {
        var state: UInt64 = 0x5EED
        func next() -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(truncatingIfNeeded: state >> 33)
        }
        var compared = 0
        for name in Self.streams {
            let stream = try Self.bytes("\(name).lzo")
            let size = try Self.bytes("\(name).raw").count
            for trial in 0 ..< 60 {
                var mutated = stream
                switch trial % 4 {
                    case 0: mutated[next() % mutated.count] ^= UInt8(1 << (next() % 8))
                    case 1: mutated[next() % mutated.count] = UInt8(truncatingIfNeeded: next())
                    case 2: mutated = Array(mutated.prefix(next() % mutated.count))
                    default: break
                }
                let capacity = trial % 4 == 3 ? max(0, size - 1 - next() % max(1, size)) : size
                let expected = Result { () throws(DiskError) in
                    try LZO1XReference.decompress(mutated, capacity: capacity)
                }
                let actual = Result { () throws(DiskError) in try LZO1X.decompress(mutated, capacity: capacity) }
                switch (expected, actual) {
                    case (.success(let want), .success(let got)):
                        #expect(want == got, "\(name), trial \(trial): different output")
                    case (.failure, .failure):
                        break
                    default:
                        Issue.record(
                            "\(name), trial \(trial): reference \(expected.map(\.count)), rewrite \(actual.map(\.count))"
                        )
                }
                compared += 1
            }
        }
        #expect(compared >= 96 * 60)
    }
}
