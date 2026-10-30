import AemiTestKit
import CFSKernels
import CodecOracle
import Foundation
import Testing

/// MacFS's DEFLATE decoder (`fsk_inflate`, Btrfs zlib extents) against the system libz (`fsk_oracle_inflate`), the reference
/// implementation: the same result, and on success the same length and bytes, on libz's own streams at every level, strategy,
/// window and memory level, on zlib's inflate coverage vectors, on hand-built streams for the rules libz's encoder never
/// writes, on every bit flip and every cut of small streams, and with the input and the output flush against an inaccessible page.
@Suite struct InflateTests {
    /// One decode: the status, and the bytes produced when it is 0.
    struct Outcome: Equatable, CustomStringConvertible {
        let status: Int32
        let output: [UInt8]
        var description: String { "status \(status), \(output.count) bytes" }
    }

    typealias Decoder = (UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UInt8>, Int, UnsafeMutablePointer<Int>) ->
        Int32

    static func decode(_ stream: [UInt8], capacity: Int, with decoder: Decoder) -> Outcome {
        var output = [UInt8](repeating: 0xEE, count: capacity + 16)
        var produced = 0
        let status = stream.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer {
                decoder(source.baseAddress!, stream.count, $0.baseAddress!, capacity, &produced)
            }
        }
        #expect(output[capacity...].allSatisfy { $0 == 0xEE }, "a write past the capacity")
        return Outcome(status: status, output: status == 0 ? Array(output[..<produced]) : [])
    }

    /// Whether MacFS and libz agree on `stream` into `capacity` bytes; the two outcomes when not.
    static func difference(_ stream: [UInt8], capacity: Int) -> String? {
        let source = stream.isEmpty ? [0] : stream
        let count = stream.count
        let ours = decode(source, capacity: capacity) { fsk_inflate($0, count, $2, $3, $4) }
        let reference = decode(source, capacity: capacity) { fsk_oracle_inflate($0, count, $2, $3, $4) }
        return ours == reference ? nil : "\(ours), libz \(reference)"
    }

    static func deflate(_ data: [UInt8], level: Int32, window: Int32 = 15, memory: Int32 = 8, strategy: Int32 = 0)
        -> [UInt8]
    {
        var stream = [UInt8](repeating: 0, count: fsk_oracle_deflate_bound(data.count))
        let length = data.withUnsafeBufferPointer { source in
            stream.withUnsafeMutableBufferPointer {
                fsk_oracle_deflate(
                    source.baseAddress ?? UnsafePointer(bitPattern: 1)!, data.count, $0.baseAddress!, $0.count, level,
                    window, memory, strategy)
            }
        }
        precondition(length >= 0, "libz deflate failed")
        return Array(stream[..<Int(length)])
    }

    /// Inputs of every kind a file system holds: text, source code, random bytes, runs, short patterns, nothing.
    static let inputs: [(String, [UInt8])] = {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let code = ["CFSKernels/zstd.c", "CFSKernels/kernels_arm64.S", "Btrfs/BtrfsCompression.swift"]
            .flatMap { (try? [UInt8](Data(contentsOf: sources.appendingPathComponent($0)))) ?? [] }
        var random = SplitMix(state: 1951)
        let noise = random.bytes(70_000)
        let words = (0 ..< 20_000).map { _ in ["the ", "of ", "and ", "block ", "tree ", "\n"][Int(random.next() % 6)] }
        return [
            ("source code", code), ("random", noise), ("text", Array(words.joined().utf8)),
            ("zeros", [UInt8](repeating: 0, count: 300_000)), ("a run", [UInt8](repeating: 0x61, count: 1000)),
            ("a short period", (0 ..< 50_000).map { UInt8($0 % 7) }), ("one byte", [0x41]), ("nothing", []),
            ("half random", (0 ..< 60_000).map { $0 % 2 == 0 ? noise[$0] : UInt8($0 % 3) }),
            ("short", Array("abcabcabcabcabd".utf8))
        ]
    }()

    @Test func libzStreamsDecodeToTheirOriginal() {
        var differ: [String] = []
        var checked = 0
        var random = SplitMix(state: 7)
        typealias Setting = (level: Int32, window: Int32, memory: Int32, strategy: Int32)
        var settings: [Setting] = (0 ... 9).map { ($0, 15, 8, 0) }
        settings += (1 ... 4).map { (6, 15, 8, $0) }
        settings += [
            (6, 9, 8, 0), (6, 12, 8, 0), (9, 15, 1, 0), (9, 15, 9, 0), (1, 9, 1, 0), (3, 15, 8, 4), (9, 15, 9, 1)
        ]
        for (name, data) in Self.inputs {
            for setting in settings {
                let stream = Self.deflate(
                    data, level: setting.level, window: setting.window, memory: setting.memory,
                    strategy: setting.strategy)
                let what = "\(name) \(setting)"
                let count = stream.count
                let ours = Self.decode(stream, capacity: data.count) { fsk_inflate($0, count, $2, $3, $4) }
                if ours != Outcome(status: 0, output: data) { differ.append("\(what): \(ours)") }
                let room = Int(random.next() % UInt64(data.count + 1))
                for capacity in [data.count + 100, max(1, data.count - 1), max(1, room)] {
                    if let difference = Self.difference(stream, capacity: capacity) {
                        differ.append("\(what) into \(capacity): \(difference)")
                    }
                }
                checked += 1
            }
        }
        #expect(checked == Self.inputs.count * settings.count)
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(6))")
    }

    /// zlib 1.2.12's own inflate tests (test/infcover.c, cover_inflate and cover_fast): the raw DEFLATE inputs, each with a
    /// rule of the decoder, valid or not. Its expected verdicts assume its streaming API; here libz's one-shot verdict through
    /// the same call, at several capacities, is the reference.
    static let infcover = [
        "0 0 0 0 0", "3 0", "6", "1 1 0 fe ff 0", "fc 0 0", "4 0 fe ff", "4 0 24 49 0", "4 0 24 e9 ff ff",
        "4 0 24 e9 ff 6d", "4 80 49 92 24 49 92 24 71 ff ff 93 11 0", "4 80 49 92 24 49 92 24 f b4 ff ff c3 84",
        "4 c0 81 8 0 0 0 0 20 7f eb b 0 0", "2 7e ff ff", "c c0 81 0 0 0 0 0 90 ff 6b 4 0",
        "5 c0 21 d 0 0 0 80 b0 fe 6d 2f 91 6c", "5 e0 81 91 24 cb b2 2c 49 e2 f 2e 8b 9a 47 56 9f fb fe ec d2 ff 1f",
        "ed c0 1 1 0 0 0 40 20 ff 57 1b 42 2c 4f",
        "ed cf c1 b1 2c 47 10 c4 30 fa 6f 35 1d 1 82 59 3d fb be 2e 2a fc f c",
        "ed c0 81 0 0 0 0 80 a0 fd a9 17 a9 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 6",
        "2 8 20 80 0 3 0", "63 18 5 40 c 0",
        "e5 e0 81 ad 6d cb b2 2c c9 01 1e 59 63 ae 7d ee fb 4d fd b5 35 41 68 ff 7f 0f 0 0 0",
        "25 fd 81 b5 6d 59 b6 6a 49 ea af 35 6 34 eb 8c b9 f6 b9 1e ef 67 49 50 fe ff ff 3f 0 0", "3 7e 0 0 0 0 0",
        "1b 7 0 0 0 0 0", "d c7 1 ae eb 38 c 4 41 a0 87 72 de df fb 1f b8 36 b1 38 5d ff ff 0",
        "63 18 5 8c 10 8 0 0 0 0",
        "63 60 60 18 c9 0 8 18 18 18 26 c0 28 0 29 0 0 0", "63 0 3 0 0 0 0 0", "63 0", "63 18 5", "63 18 68 30 d0 0 0"
    ]
    .map { $0.split(separator: " ").map { UInt8($0, radix: 16)! } }

    @Test func zlibCoverageVectorsGetLibzVerdict() {
        var differ: [String] = []
        for (index, stream) in Self.infcover.enumerated() {
            for capacity in [1, 2, 3, 257, 258, 259, 300, 1 << 16] {
                if let difference = Self.difference(stream, capacity: capacity) {
                    differ.append("vector \(index) into \(capacity): \(difference)")
                }
            }
        }
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(6))")
    }

    /// The hand-built streams of CodecOracle (`fsk_oracle_vector`), each a rule libz's encoder never writes: flushed blocks,
    /// codes without distances, lone 1-bit codes, codes one 15-bit code short, too many and all of the code lengths, an
    /// all-zero precode, no end-of-block code, headers at the input's end, distance codes 30 and 31, a full output before an
    /// error, 48-bit symbols at every alignment, a stored block between fast blocks, random deep codes. libz's verdict on
    /// each into capacities around its rule, and on its cuts (every one of the small streams, every 13th of the others).
    @Test func handBuiltStreamsGetLibzVerdict() {
        var differ: [String] = []
        var checked = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        for which in 0 ..< fsk_oracle_vector_count() {
            var name: UnsafePointer<CChar>?
            var size = 0
            let length = buffer.withUnsafeMutableBufferPointer {
                fsk_oracle_vector(which, $0.baseAddress!, $0.count, &name, &size)
            }
            let what = "\(which) \(name.map { String(cString: $0) } ?? "")"
            guard length > 0 else {
                differ.append("\(what): does not fit")
                continue
            }
            let stream = Array(buffer[..<length])
            let capacities = Set([
                1, 2, 3, 4, 5, 6, 9, 257, 258, 259, 300, max(1, size - 1), max(1, size), size + 1, size + 300
            ])
            for capacity in capacities.sorted() {
                if let difference = Self.difference(stream, capacity: capacity) {
                    differ.append("\(what) into \(capacity): \(difference)")
                }
                checked += 1
            }
            var cut = 0
            while cut < length {
                if let difference = Self.difference(Array(stream[..<cut]), capacity: size + 1) {
                    differ.append("\(what) cut at \(cut): \(difference)")
                }
                checked += 1
                cut += length <= 1024 || cut + 32 >= length ? 1 : 13
            }
        }
        #expect(checked > 10_000, "\(checked)")
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(6))")
    }

    /// Every single-bit flip of small streams of each strategy, every cut of them, and arbitrary bytes after each block
    /// header: libz's verdict on each, into the original's size and into a larger buffer.
    @Test func damagedStreamsGetLibzVerdict() {
        var differ: [String] = []
        var checked = 0
        var random = SplitMix(state: 9)
        let text = Array(Self.inputs[2].1.prefix(900))
        let small: [[UInt8]] = [
            Self.deflate(text, level: 6), Self.deflate(text, level: 1, strategy: 4),
            Self.deflate(text, level: 6, strategy: 2),
            Self.deflate(Array(Self.inputs[0].1.prefix(700)), level: 9), Self.deflate(Array(text.prefix(60)), level: 0),
            Self.deflate(Array(Self.inputs[5].1.prefix(2000)), level: 6, strategy: 3)
        ]
        for stream in small {
            for bit in 0 ..< stream.count * 8 {
                var flipped = stream
                flipped[bit / 8] ^= UInt8(1 << (bit % 8))
                for capacity in [900, 4096] {
                    if let difference = Self.difference(flipped, capacity: capacity) {
                        differ.append("flip \(bit) into \(capacity): \(difference)")
                    }
                    checked += 1
                }
            }
            for cut in 0 ..< stream.count {
                if let difference = Self.difference(Array(stream[..<cut]), capacity: 4096) {
                    differ.append("cut at \(cut): \(difference)")
                }
            }
        }
        for trial in 0 ..< 3000 {
            let header = UInt8(trial % 8)
            let stream = [header | UInt8(random.next() % 32) << 3] + random.bytes(Int(random.next() % 64))
            if let difference = Self.difference(stream, capacity: Int(random.next() % 600) + 1) {
                differ.append("arbitrary \(stream): \(difference)")
            }
        }
        #expect(checked > 35_000, "\(checked)")  // 35,648 with libz 1.2.12: the six streams are not empty
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(6))")
    }

    /// Streams flush against an inaccessible page, decoded into exactly their original's size, also flush: a read past the
    /// input or a write past the output traps.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func streamsStayInsideTheirBuffers(edge: GuardedBytes.Edge) {
        var random = SplitMix(state: 11)
        for (name, data) in Self.inputs where !data.isEmpty {
            for strategy: Int32 in [0, 2, 3, 4] {
                let full = Self.deflate(data, level: 6, strategy: strategy)
                let stream =
                    random.next() % 3 == 0 ? Array(full.prefix(1 + Int(random.next() % UInt64(full.count)))) : full
                let capacity = random.next() % 3 == 0 ? 1 + Int(random.next() % UInt64(data.count)) : data.count
                GuardedBytes.with(stream, against: edge) { source in
                    GuardedBytes.with([UInt8](repeating: 0, count: capacity), against: edge) { target in
                        var produced = 0
                        let status = fsk_inflate(source, stream.count, target, capacity, &produced)
                        if stream.count == full.count {
                            #expect(status == 0, "\(name) \(strategy)")
                            #expect(
                                Array(UnsafeBufferPointer(start: target, count: produced))
                                    == Array(data.prefix(capacity)),
                                "\(name) \(strategy)")
                        }
                    }
                }
            }
        }
    }
}
