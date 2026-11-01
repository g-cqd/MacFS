import AemiTestKit
import CFSKernels
import FSCore
import Foundation
import Testing

@testable import Btrfs

/// The zstd decoder (roadmap 0013) against the reference implementation: frames the zstd CLI wrote (TestImages/zstd, every
/// level, with and without checksum and content size, around the block size, two frames in a row), zstd's own golden files
/// and 1,000 random valid frames from its decodecorpus generator (TestCorpus/zstd); and damaged frames, which fail or decode
/// to the original when a checksum vouches for it, never trap and never touch a byte outside their buffers.
@Suite struct ZstdTests {
    static let fixtures = ImageOracle.directory.appendingPathComponent("zstd")
    static let corpus = ImageOracle.directory.deletingLastPathComponent().appendingPathComponent("TestCorpus/zstd")

    static func names(_ directory: URL, suffix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }.sorted()
    }

    static let streams = names(fixtures, suffix: ".zst")
    static func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    @Test func theFixturesAndTheCorpusAreThere() {
        #expect(Self.streams.count >= 100, "run the images command")
        #expect(
            Self.names(Self.corpus.appendingPathComponent("decodecorpus/frames"), suffix: ".zst").count == 1000,
            "run the images command with --corpus"
        )
    }

    @Test(arguments: streams)
    func everyCLIFrameDecodesToItsOriginal(_ name: String) throws {
        let stream = try Self.bytes(Self.fixtures.appendingPathComponent("\(name).zst"))
        let original = try Self.bytes(Self.fixtures.appendingPathComponent("\(name).raw"))
        #expect(try Zstd.decompress(stream, capacity: original.count) == original)
        if !original.isEmpty {
            #expect(throws: DiskError.self, "one byte short of room") {
                try Zstd.decompress(stream, capacity: original.count - 1)
            }
        }
    }

    @Test func aFrameEndsWhereItsLengthSays() throws {
        let first = try Self.bytes(Self.fixtures.appendingPathComponent("counting-1.zst"))
        let both = try Self.bytes(Self.fixtures.appendingPathComponent("two-frames.zst"))
        let (bytes, consumed) = try Zstd.decompressFrame(both + [0, 0, 0], capacity: 2 << 20)
        #expect(consumed == first.count)
        #expect(bytes == (try Self.bytes(Self.fixtures.appendingPathComponent("counting-1.raw"))))
        // A Btrfs extent: the frame, then zeros to the end of its sector.
        #expect(
            try Zstd.decompressFrame(first + [UInt8](repeating: 0, count: 3000), capacity: 2 << 20).consumed
                == first.count
        )
    }

    @Test func everyDecodecorpusFrameDecodesToItsOriginal() throws {
        let frames = Self.corpus.appendingPathComponent("decodecorpus/frames")
        for name in Self.names(frames, suffix: ".zst") {
            let original = try Self.bytes(Self.corpus.appendingPathComponent("decodecorpus/originals/\(name)"))
            let stream = try Self.bytes(frames.appendingPathComponent("\(name).zst"))
            #expect(try Zstd.decompress(stream, capacity: original.count) == original, "\(name)")
        }
    }

    @Test func zstdsGoldenFilesDecodeAndItsErrorFilesAreRefused() throws {
        let golden = Self.corpus.appendingPathComponent("golden-decompression")
        let goldenNames = Self.names(golden, suffix: ".zst")
        #expect(goldenNames.count >= 4)
        for name in goldenNames {
            _ = try Zstd.decompress(try Self.bytes(golden.appendingPathComponent("\(name).zst")), capacity: 1 << 22)
        }
        let errors = Self.corpus.appendingPathComponent("golden-decompression-errors")
        let errorNames = Self.names(errors, suffix: ".zst")
        #expect(errorNames.count >= 3)
        for name in errorNames {
            #expect(throws: DiskError.self, "\(name)") {
                try Zstd.decompress(try Self.bytes(errors.appendingPathComponent("\(name).zst")), capacity: 1 << 22)
            }
        }
    }

    /// Damaged checksummed frames: whatever decodes is the original (the checksum vouches), the rest is refused. Input and
    /// output each flush against an inaccessible page.
    @Test(arguments: GuardedBytes.Edge.allCases)
    func damagedFramesFailOrDecodeTheOriginalInsideTheirBuffers(edge: GuardedBytes.Edge) throws {
        var random = SplitMix(state: 31)
        let workspace = UnsafeMutableRawPointer.allocate(byteCount: fsk_zstd_workspace_size(), alignment: 16)
        defer { workspace.deallocate() }
        for name in Self.streams where name.hasSuffix("-check") {
            let stream = try Self.bytes(Self.fixtures.appendingPathComponent("\(name).zst"))
            let original = try Self.bytes(Self.fixtures.appendingPathComponent("\(name).raw"))
            for trial in 0 ..< 40 {
                var damaged = stream
                switch trial % 3 {
                    case 0:
                        damaged[Int(random.next() % UInt64(stream.count))] ^= UInt8(
                            truncatingIfNeeded: random.next() | 1
                        )
                    case 1:
                        damaged[Int(random.next() % UInt64(stream.count))] = UInt8(truncatingIfNeeded: random.next())
                    default: damaged = Array(stream.prefix(Int(random.next() % UInt64(stream.count)) + 1))
                }
                // The workspace starts as whatever the last decode left: the kernel may not rely on its contents.
                GuardedBytes.with(damaged, against: edge) { source in
                    GuardedBytes.with([UInt8](repeating: 0xEE, count: max(1, original.count)), against: edge) {
                        target in
                        var consumed = 0
                        let result = fsk_zstd_decompress_frame(
                            source,
                            damaged.count,
                            target,
                            original.count,
                            workspace,
                            &consumed
                        )
                        if result >= 0 {
                            #expect(
                                Array(UnsafeBufferPointer(start: target, count: Int(result))) == original,
                                "\(name), trial \(trial)"
                            )
                        }
                    }
                }
            }
        }
    }

    /// 2,400 damaged decodecorpus frames (TestCorpus/zstd/damaged) with the reference decoder's verdict: refused where it
    /// refuses, the same bytes where it decodes. Every error path is held to the reference's, not only to "no trap".
    @Test func damagedFramesGetTheReferenceVerdict() throws {
        let damaged = Self.corpus.appendingPathComponent("damaged")
        let index = try String(contentsOf: damaged.appendingPathComponent("index.tsv"), encoding: .utf8)
        var checked = 0
        var differ: [String] = []
        for line in index.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            let frame = try Self.bytes(damaged.appendingPathComponent(fields[0]))
            let ours = try? Zstd.decompress(frame, capacity: 1 << 23)
            if fields[1] == "ok" {
                let expected = try Self.bytes(damaged.appendingPathComponent("\(fields[0]).out"))
                if ours != expected { differ.append("\(fields[0]): the reference decodes it") }
            } else if ours != nil {
                differ.append("\(fields[0]): the reference refuses it")
            }
            checked += 1
        }
        #expect(checked == 2_400)
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(8))")
    }

    /// Every single-bit flip of 40 decodecorpus frames (87,008 frames, TestCorpus/zstd/flips) against the reference's
    /// verdict: refused where it refuses; where it decodes, the same length and XXH64.
    @Test func everyBitFlipGetsTheReferenceVerdict() throws {
        let index = try String(contentsOf: Self.corpus.appendingPathComponent("flips/index.tsv"), encoding: .utf8)
        var frames: [String: [UInt8]] = [:]
        var checked = 0
        var differ: [String] = []
        for line in index.split(separator: "\n") {
            let fields = line.split(separator: "\t").map(String.init)
            let name = fields[0]
            if frames[name] == nil {
                frames[name] = try Self.bytes(Self.corpus.appendingPathComponent("decodecorpus/frames/\(name)"))
            }
            guard var frame = frames[name], let byte = Int(fields[1]), let bit = Int(fields[2]) else { continue }
            frame[byte] ^= UInt8(1 << bit)
            let ours = try? Zstd.decompress(frame, capacity: 8 << 20)
            if fields[3] == "error" {
                if ours != nil { differ.append("\(name) \(byte).\(bit): the reference refuses it") }
            } else {
                let hash = ours.map { bytes in
                    (bytes.isEmpty ? [0] : bytes).withUnsafeBufferPointer { fsk_xxh64($0.baseAddress!, bytes.count) }
                }
                if ours?.count != Int(fields[4])
                    || hash.map({ String($0, radix: 16) }) != String(fields[5].drop { $0 == "0" })
                {
                    differ.append("\(name) \(byte).\(bit): the reference decodes it")
                }
            }
            checked += 1
        }
        #expect(checked > 80_000)
        #expect(differ.isEmpty, "\(differ.count) differ: \(differ.prefix(8))")
    }

    /// Frames built by hand for checks no corpus reaches, each with libzstd 1.5.7's one-shot verdict (checked when written).
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
    static let window1MiB: UInt8 = (20 - 10) << 3

    static func block(last: Bool = true, type: UInt32, size: Int, _ content: [UInt8]) -> [UInt8] {
        let header = (last ? 1 : 0) | type << 1 | UInt32(size) << 3
        return [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16)] + content
    }

    static func frame(window: UInt8 = window1MiB, descriptor: UInt8 = 0, extra: [UInt8] = [], _ blocks: [UInt8])
        -> [UInt8]
    {
        magic + [descriptor, window] + extra + blocks
    }

    /// A compressed block of `literals` (a literals section) and no sequences.
    static func literalsBlock(_ literals: [UInt8]) -> [UInt8] {
        block(type: 2, size: literals.count + 1, literals + [0])
    }

    /// Compressed literals, one stream (format 0) or four (format 1): 3-byte header, `regenerated`, then `body`.
    static func huffmanLiterals(format: UInt32, regenerated: UInt32, _ body: [UInt8]) -> [UInt8] {
        let header = 2 | format << 2 | regenerated << 4 | UInt32(body.count) << 14
        return [UInt8(header & 0xFF), UInt8(header >> 8 & 0xFF), UInt8(header >> 16)] + body
    }

    /// Compressed literals with a 5-byte header (format 3: four streams, 18-bit sizes).
    static func fiveByteHuffmanLiterals(regenerated: UInt64, _ body: [UInt8]) -> [UInt8] {
        let header = 2 | 3 << 2 | regenerated << 4 | UInt64(body.count) << 22
        return (0 ..< 5).map { UInt8(truncatingIfNeeded: header >> (8 * $0)) } + body
    }

    /// A Huffman table is the frame's own: in a workspace that still holds the last frame's, treeless literals in a new
    /// frame's first block are refused, as the reference refuses them (the table alone would decode them).
    @Test func aHuffmanTableDoesNotOutliveItsFrame() throws {
        let withTable = Self.frame(
            Self.literalsBlock(Self.huffmanLiterals(format: 0, regenerated: 4, [129, 0x21, 0x1F]))
        )
        let treeless = Self.frame(
            Self.literalsBlock(
                Self.huffmanLiterals(format: 0, regenerated: 4, [0x1F]).enumerated()
                    .map {
                        $0.offset == 0 ? $0.element | 3 : $0.element
                    }
            )
        )
        let workspace = UnsafeMutableRawPointer.allocate(byteCount: fsk_zstd_workspace_size(), alignment: 16)
        defer { workspace.deallocate() }
        var output = [UInt8](repeating: 0xEE, count: 64)
        var consumed = 0
        let first = output.withUnsafeMutableBufferPointer {
            fsk_zstd_decompress_frame(withTable, withTable.count, $0.baseAddress!, 64, workspace, &consumed)
        }
        #expect(first == 4 && output.prefix(4) == [0, 0, 0, 0], "the reference decodes it to four zeros")
        let second = output.withUnsafeMutableBufferPointer {
            fsk_zstd_decompress_frame(treeless, treeless.count, $0.baseAddress!, 64, workspace, &consumed)
        }
        #expect(second == -1)
    }

    @Test func handBuiltFramesGetTheReferenceVerdict() throws {
        // The reference holds raw and RLE blocks only to the room left, not to the window or 128 KiB.
        #expect(
            try Zstd.decompress(Self.frame(window: 0, Self.block(type: 1, size: 2048, [0x61])), capacity: 4096)
                == [UInt8](repeating: 0x61, count: 2048)
        )
        let big = [UInt8](repeating: 0x78, count: 131_073)
        #expect(try Zstd.decompress(Self.frame(Self.block(type: 0, size: big.count, big)), capacity: 1 << 18) == big)
        let refused: [(String, [UInt8])] = [
            // RLE literals of 2^20 - 1 bytes: more than a block holds, and more than the workspace.
            ("RLE literals past 128 KiB", Self.frame(Self.literalsBlock([1 | 3 << 2 | 0xF0, 0xFF, 0xFF, 0x7A]))),
            // One sequence, literal lengths RLE with symbol 36: past the 35 codes.
            ("an RLE symbol out of range", Self.frame(Self.block(type: 2, size: 5, [0x00, 1, 0x40, 36, 0x01]))),
            // Direct weights 3 and 1: 5, which no implied weight brings to a power of two; the stream would decode against
            // the table that leaves one cell empty (four zero bytes, each a 1-bit code).
            (
                "incomplete Huffman weights",
                Self.frame(Self.literalsBlock(Self.huffmanLiterals(format: 0, regenerated: 4, [129, 0x31, 0x1B])))
            ),
            // Treeless literals in the first block: no table to reuse.
            (
                "treeless literals first",
                Self.frame(
                    Self.literalsBlock(
                        Self.huffmanLiterals(format: 0, regenerated: 4, [0x1B]).enumerated()
                            .map {
                                $0.offset == 0 ? $0.element | 3 : $0.element
                            }
                    )
                )
            ),
            // Four streams for two literals.
            (
                "four streams for two literals",
                Self.frame(
                    Self.literalsBlock(
                        Self.huffmanLiterals(
                            format: 1,
                            regenerated: 2,
                            [129, 0x11, 1, 0, 1, 0, 1, 0, 0x80, 0x80, 0x80, 0x80]
                        )
                    )
                )
            ),
            // Four streams for two literals, the fourth long: its count would be 2 - 3 symbols, written without end.
            (
                "a long fourth stream for two literals",
                Self.frame(
                    Self.literalsBlock(
                        Self.fiveByteHuffmanLiterals(
                            regenerated: 2,
                            [129, 0x11, 1, 0, 1, 0, 1, 0, 0x03, 0x03, 0x03] + [UInt8](repeating: 0xFF, count: 20_000)
                        )
                    )
                )
            ),
            // FSE-coded weights whose only symbol takes the whole table: its states read no bits, without end.
            (
                "endless Huffman weights",
                Self.frame(
                    Self.literalsBlock(
                        Self.huffmanLiterals(
                            format: 0,
                            regenerated: 4,
                            [3, 0x10, 0x02, 0x80, 0x80]
                        )
                    )
                )
            )
        ]
        for (what, frame) in refused {
            #expect(throws: DiskError.self, "\(what)") { try Zstd.decompress(frame, capacity: 1 << 21) }
        }
        #expect(throws: DiskError.unsupported("zstd frames that need a dictionary")) {
            try Zstd.decompress(
                Self.frame(descriptor: 0x01, extra: [5], Self.block(type: 0, size: 3, [0x61, 0x62, 0x63])),
                capacity: 100
            )
        }
        #expect(
            try Zstd.decompress(Self.frame(Self.block(type: 0, size: 3, [0x61, 0x62, 0x63])), capacity: 100) == [
                0x61, 0x62, 0x63
            ]
        )
    }

    /// The content checksum is XXH64's low half: known vectors of the hash itself.
    @Test func xxh64KnownVectors() {
        #expect(fsk_xxh64([0], 0) == 0xEF46_DB37_51D8_E999)
        #expect(Array("abc".utf8).withUnsafeBufferPointer { fsk_xxh64($0.baseAddress!, 3) } == 0x44BC_2CF5_AD77_0999)
    }
}
