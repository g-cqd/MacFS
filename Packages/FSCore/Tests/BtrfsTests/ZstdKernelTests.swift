import AemiTestKit
import CFSKernels
import FSCore
import Foundation
import Testing

@testable import Btrfs

@_silgen_name("fsk_ref_zstd_decompress_frame")
func referenceZstdFrame(
    _ source: UnsafePointer<UInt8>, _ count: Int, _ target: UnsafeMutablePointer<UInt8>, _ capacity: Int,
    _ workspace: UnsafeMutableRawPointer, _ consumed: UnsafeMutablePointer<Int>
) -> Int64

/// The arm64 sequence kernel (kernels_zstd_arm64.S) against the C sequence loop it replaces (`fsk_ref_zstd_decompress_frame`,
/// the same decoder with the C loop): the same result, the same length consumed and the same bytes up to the result, on every
/// frame of the CLI fixtures and the decodecorpus, on the damaged corpus, on every bit flip of the flips corpus, and with the
/// output flush against an inaccessible page.
@Suite struct ZstdKernelTests {
    /// A workspace for each decoder, for one test (tests run in parallel).
    final class Workspaces {
        let kernel = UnsafeMutableRawPointer.allocate(byteCount: fsk_zstd_workspace_size(), alignment: 16)
        let reference = UnsafeMutableRawPointer.allocate(byteCount: fsk_zstd_workspace_size(), alignment: 16)
        deinit {
            kernel.deallocate()
            reference.deallocate()
        }
    }

    let workspaces = Workspaces()

    /// Whether kernel and reference agree on `frame` into `capacity` bytes; a description of the difference when not.
    func difference(_ frame: [UInt8], capacity: Int) -> String? {
        guard !frame.isEmpty else { return nil }
        var kernel = [UInt8](repeating: 0xEE, count: capacity + 16)
        var reference = [UInt8](repeating: 0xDD, count: capacity + 16)
        var (kernelUsed, referenceUsed) = (0, 0)
        let (k, r) = frame.withUnsafeBufferPointer { source in
            (
                kernel.withUnsafeMutableBufferPointer {
                    fsk_zstd_decompress_frame(
                        source.baseAddress!, frame.count, $0.baseAddress!, capacity, workspaces.kernel, &kernelUsed)
                },
                reference.withUnsafeMutableBufferPointer {
                    referenceZstdFrame(
                        source.baseAddress!, frame.count, $0.baseAddress!, capacity, workspaces.reference,
                        &referenceUsed)
                }
            )
        }
        if k != r { return "result \(k), reference \(r)" }
        if k >= 0, kernelUsed != referenceUsed { return "consumed \(kernelUsed), reference \(referenceUsed)" }
        if k > 0, kernel[..<Int(k)] != reference[..<Int(k)] { return "bytes" }
        if kernel[capacity...].contains(where: { $0 != 0xEE }) { return "a write past the capacity" }
        return nil
    }

    static func frames(_ directory: String) throws -> [(String, [UInt8])] {
        let url = ZstdTests.corpus.appendingPathComponent(directory)
        return try ZstdTests.names(url, suffix: ".zst")
            .map { ($0, try ZstdTests.bytes(url.appendingPathComponent("\($0).zst"))) }
    }

    @Test func everyFixtureAndCorpusFrameDecodesTheSame() throws {
        var differ: [String] = []
        var checked = 0
        for name in ZstdTests.streams {
            let frame = try ZstdTests.bytes(ZstdTests.fixtures.appendingPathComponent("\(name).zst"))
            let size = try ZstdTests.bytes(ZstdTests.fixtures.appendingPathComponent("\(name).raw")).count
            for capacity in [size, size + 100, max(0, size - 1)] {
                if let difference = difference(frame, capacity: capacity) {
                    differ.append("\(name) into \(capacity): \(difference)")
                }
                checked += 1
            }
        }
        let corpus = try Self.frames("decodecorpus/frames") + Self.frames("golden-decompression") + Self.frames("wide")
        for (name, frame) in corpus {
            for capacity in [8 << 20, 1 << 22] {
                if let difference = difference(frame, capacity: capacity) { differ.append("\(name): \(difference)") }
                checked += 1
            }
        }
        #expect(checked > 2_302)
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(8))")
    }

    /// The damaged corpus, every bit flip of the flips corpus, and decodecorpus frames cut short or given too little room.
    @Test func damagedFramesDecodeOrFailTheSame() throws {
        var differ: [String] = []
        let damaged = ZstdTests.corpus.appendingPathComponent("damaged")
        let index = try String(contentsOf: damaged.appendingPathComponent("index.tsv"), encoding: .utf8)
        for line in index.split(separator: "\n") {
            let name = String(line.split(separator: "\t")[0])
            if let difference = difference(try ZstdTests.bytes(damaged.appendingPathComponent(name)), capacity: 1 << 23)
            {
                differ.append("\(name): \(difference)")
            }
        }
        let flips = try String(
            contentsOf: ZstdTests.corpus.appendingPathComponent("flips/index.tsv"), encoding: .utf8)
        var frames: [String: [UInt8]] = [:]
        var checked = 0
        for line in flips.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            if frames[fields[0]] == nil {
                frames[fields[0]] = try ZstdTests.bytes(
                    ZstdTests.corpus.appendingPathComponent("decodecorpus/frames/\(fields[0])"))
            }
            guard var frame = frames[fields[0]], let byte = Int(fields[1]), let bit = Int(fields[2]) else { continue }
            frame[byte] ^= UInt8(1 << bit)
            if let difference = difference(frame, capacity: 8 << 20) {
                differ.append("\(fields[0]) \(byte).\(bit): \(difference)")
            }
            checked += 1
        }
        var random = SplitMix(state: 41)
        for (name, frame) in try Self.frames("decodecorpus/frames").prefix(300) {
            let cut = Array(frame.prefix(1 + Int(random.next() % UInt64(frame.count))))
            if let difference = difference(cut, capacity: 8 << 20) { differ.append("\(name) cut: \(difference)") }
            let room = Int(random.next() % 70_000)
            if let difference = difference(frame, capacity: room) {
                differ.append("\(name) into \(room): \(difference)")
            }
        }
        #expect(checked > 80_000)
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(8))")
    }

    /// Every decodecorpus frame into exactly its original's size, the output flush against an inaccessible page: the kernel's
    /// 16-byte moves must stop at the capacity. Then the same frames cut short, the input flush against the page.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func framesStayInsideTheirBuffers(edge: GuardedBytes.Edge) throws {
        var random = SplitMix(state: 43)
        for (name, frame) in try Self.frames("decodecorpus/frames") {
            let original = try ZstdTests.bytes(
                ZstdTests.corpus.appendingPathComponent("decodecorpus/originals/\(name)"))
            let input =
                random.next() % 2 == 0 ? frame : Array(frame.prefix(1 + Int(random.next() % UInt64(frame.count))))
            GuardedBytes.with(input, against: edge) { source in
                GuardedBytes.with([UInt8](repeating: 0, count: max(1, original.count)), against: edge) { target in
                    var consumed = 0
                    let result = fsk_zstd_decompress_frame(
                        source, input.count, target, original.count, workspaces.kernel, &consumed)
                    if input.count == frame.count {
                        #expect(result == Int64(original.count), "\(name)")
                        #expect(Array(UnsafeBufferPointer(start: target, count: original.count)) == original, "\(name)")
                    }
                }
            }
        }
    }

    /// The frame of sequences of more than 57 bits that are not the last of their block (Scripts/zstd-wide.c), some in cells
    /// whose states start above 0: the kernel's Lzs_wide path, which no CLI frame reaches, against libzstd's original.
    @Test func wideSequencesDecodeToTheirOriginal() throws {
        let directory = ZstdTests.corpus.appendingPathComponent("wide")
        let frame = try ZstdTests.bytes(directory.appendingPathComponent("wide-sequences.zst"))
        let original = try ZstdTests.bytes(directory.appendingPathComponent("wide-sequences.raw"))
        GuardedBytes.with([UInt8](repeating: 0, count: original.count), against: .end) { target in
            var consumed = 0
            let result = frame.withUnsafeBufferPointer {
                fsk_zstd_decompress_frame(
                    $0.baseAddress!, frame.count, target, original.count, workspaces.kernel, &consumed)
            }
            #expect(result == Int64(original.count))
            #expect(consumed == frame.count)
            #expect(Array(UnsafeBufferPointer(start: target, count: original.count)) == original)
        }
    }

    /// Raw literals, their header first.
    static func rawLiterals(_ literals: [UInt8]) -> [UInt8] {
        let count = literals.count
        if count < 32 { return [UInt8(count << 3)] + literals }
        return [UInt8((count & 15) << 4 | 1 << 2), UInt8(count >> 4)] + literals
    }

    /// A sequences section of `count` sequences with the three tables RLE (one symbol each: literal length, offset and match
    /// length codes), then `stream`.
    static func rleSequences(count: Int, literals: UInt8, offset: UInt8, match: UInt8, _ stream: [UInt8]) -> [UInt8] {
        let header: [UInt8] =
            count < 128
            ? [UInt8(count)]
            : count < 0x7F00
                ? [UInt8(128 + count >> 8), UInt8(count & 0xFF)]
                : [255, UInt8((count - 0x7F00) & 0xFF), UInt8((count - 0x7F00) >> 8)]
        return header + [0x54, literals, offset, match] + stream
    }

    static func compressedBlock(last: Bool = true, _ content: [UInt8]) -> [UInt8] {
        ZstdTests.block(last: last, type: 2, size: content.count, content)
    }

    /// The frame of the careful-path vectors (handBuiltBlocksGetTheReferenceVerdict): the last offset 125 + `extra`.
    static func careful(extra: UInt8) -> [UInt8] {
        ZstdTests.frame(
            ZstdTests.block(last: false, type: 1, size: 130, [0x78])
                + Self.compressedBlock(
                    Self.rawLiterals(Array("abcdefgh".utf8))
                        + Self.rleSequences(count: 8, literals: 1, offset: 7, match: 0, [extra, 0, 0, 0, 0, 0, 0, 1])))
    }

    /// What `careful(extra: 0)` decodes to: each literal, then 3 bytes from 125 back.
    static var carefulOriginal: [UInt8] {
        var output = [UInt8](repeating: 0x78, count: 130)
        for literal in "abcdefgh".utf8 {
            output.append(literal)
            for _ in 0 ..< 3 { output.append(output[output.count - 125]) }
        }
        return output
    }

    /// Blocks no frame of the CLI or of the corpora holds, each aimed at one of the kernel's checks, with the input and the
    /// output flush against an inaccessible page: the reference's verdict, and the same as the C loop's.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func handBuiltBlocksGetTheReferenceVerdict(edge: GuardedBytes.Edge) {
        // 21 sequences of 32 literals (code 22: 3 extra bits, all 0) and a match of 3, 1 back (repeat offset 1): 63 bits,
        // the stream's top bit bit 63.
        let literals = (0 ..< 672).map { UInt8(($0 * 7 + 1) % 251) }
        let valid =
            Self.rawLiterals(literals)
            + Self.rleSequences(
                count: 21, literals: 22, offset: 0, match: 0, [0, 0, 0, 0, 0, 0, 0, 0x80])
        let expected = (0 ..< 21)
            .flatMap {
                Array(literals[$0 * 32 ..< $0 * 32 + 32]) + [UInt8](repeating: literals[$0 * 32 + 31], count: 3)
            }
        let vectors: [(String, [UInt8], Int, [UInt8]?)] = [
            ("21 sequences", ZstdTests.frame(Self.compressedBlock(valid)), 735, expected),
            // The same stream followed by a zero byte: a stream's last byte holds its top bit, and this one has none.
            ("a stream ending in a zero byte", ZstdTests.frame(Self.compressedBlock(valid + [0])), 735, nil),
            // 63 sequences of 3 literals and a match of 3 at repeat offset 2 (4 at first): one byte past those produced.
            (
                "an offset one past the output",
                ZstdTests.frame(
                    Self.compressedBlock(
                        Self.rawLiterals((0 ..< 189).map { UInt8(65 + $0 % 26) })
                            + Self.rleSequences(
                                count: 63, literals: 3, offset: 1, match: 0, [0, 0, 0, 0, 0, 0, 0, 0x80]))),
                378, nil
            ),
            // 64 sequences of 65,536 literals (code 35), one literal there.
            (
                "literals past those decoded",
                ZstdTests.frame(
                    Self.compressedBlock(
                        Self.rawLiterals([0x61])
                            + Self.rleSequences(
                                count: 64, literals: 35, offset: 0, match: 0, [UInt8](repeating: 0, count: 128) + [1]))),
                8 << 20, nil
            ),
            // 130 bytes of history (an RLE block), then 8 sequences of a literal and a match of 3 at offset code 7 (7 bits
            // each: 56, an 8-byte stream), 125 back, and the last 125 + its bits back: 125 (valid), or 160, one past those
            // produced, with 4 bytes of room left (the kernel's careful path).
            ("an offset past the output, room short", Self.careful(extra: 35), 162, nil),
            ("the same, valid", Self.careful(extra: 0), 162, Self.carefulOriginal),
            // 2,048 bytes of history (an RLE block), then 40,000 sequences of a match of 3 from 1,021 to 2,044 back (offset
            // code 10: 10 bits each, every value valid) from an 8-byte stream: they read 50 KB below its start, which only
            // the end's "used up exactly" test refuses, and the kernel must read nothing below the stream meanwhile.
            (
                "a stream read far below its start",
                ZstdTests.frame(
                    ZstdTests.block(last: false, type: 1, size: 2048, [0x78])
                        + Self.compressedBlock(
                            Self.rawLiterals([])
                                + Self.rleSequences(
                                    count: 40_000, literals: 0, offset: 10, match: 0,
                                    [UInt8](repeating: 0x55, count: 7) + [0x80]))),
                1 << 20, nil
            )
        ]
        for (what, frame, capacity, original) in vectors {
            #expect(difference(frame, capacity: capacity) == nil, "\(what)")
            GuardedBytes.with(frame, against: edge) { source in
                GuardedBytes.with([UInt8](repeating: 0, count: capacity), against: edge) { target in
                    var consumed = 0
                    let result = fsk_zstd_decompress_frame(
                        source, frame.count, target, capacity, workspaces.kernel, &consumed)
                    if let original {
                        #expect(result == Int64(original.count), "\(what)")
                        #expect(Array(UnsafeBufferPointer(start: target, count: original.count)) == original, "\(what)")
                    } else {
                        #expect(result == -1, "\(what)")
                    }
                }
            }
        }
    }
}
