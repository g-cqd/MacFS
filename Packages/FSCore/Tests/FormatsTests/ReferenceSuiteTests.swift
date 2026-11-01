import FSCore
import Formats
import Foundation
import Testing

/// The reference test suites' images (`TestCorpus/`, from `macfs-tool images --corpus`; docs/conformance): e2fsprogs' damaged
/// ext images, each with e2fsck's verdict, and btrfs-progs' test images. On every one a reader ends with a result or a
/// `DiskError`: no trap, no hang. Where e2fsck finds nothing to fix (its expected output is only the passes), the whole tree
/// reads, or the reader names
/// what it does not support.
@Suite(.timeLimit(.minutes(5))) struct ReferenceSuiteTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let suite: String
        let image: String
        /// e2fsck's expected output is only its passes and the summary: a valid file system.
        let clean: Bool
        var testDescription: String { "\(suite)/\(image)" }
        var path: String { ReferenceSuiteTests.corpus.appendingPathComponent(suite).appendingPathComponent(image).path }
    }

    static let corpus = ImageOracle.directory.deletingLastPathComponent().appendingPathComponent("TestCorpus")

    static let cases: [Case] = ["e2fsprogs", "btrfs-progs"]
        .flatMap { suite -> [Case] in
            let index = corpus.appendingPathComponent(suite).appendingPathComponent("index.tsv")
            guard let text = try? String(contentsOf: index, encoding: .utf8) else { return [] }
            return text.split(separator: "\n")
                .map { line in
                    let column = line.split(separator: "\t").map(String.init)
                    return Case(
                        suite: suite,
                        image: column[0],
                        clean: suite == "e2fsprogs" && column.count > 1 && column[1] == "clean"
                    )
                }
        }

    /// Everything the image allows: every node's attributes, every link, the first 4 MiB of every file. nil when all of it read.
    static func exercise(_ path: String) -> DiskError? {
        do throws(DiskError) {
            let source = try FileBlockSource(path: path)
            guard let format = DiskFormat.detect(source) else { return .unsupported("no format detected") }
            let fileSystem = try format.open(source)
            try TreeWalk.visit(fileSystem, budget: 50_000) { (visit) throws(DiskError) in
                let attributes = try fileSystem.attributes(of: visit.entry.id)
                switch visit.entry.kind {
                    case .symlink:
                        _ = try fileSystem.readLink(visit.entry.id)
                    case .regular:
                        var offset: UInt64 = 0
                        while offset < min(attributes.size, 4 << 20) {
                            let bytes = try fileSystem.read(visit.entry.id, at: offset, count: 1 << 20)
                            guard !bytes.isEmpty else { break }
                            offset += UInt64(bytes.count)
                        }
                    default:
                        break
                }
            }
            return nil
        } catch {
            return error
        }
    }

    @Test func theCorpusIsThere() {
        #expect(
            Self.cases.count > 300,
            "run `swift package --package-path Packages/Tooling --disable-sandbox images --corpus`"
        )
        #expect(Self.cases.filter(\.clean).count > 10)
    }

    @Test(arguments: cases)
    func readsOrRefusesWithoutATrap(_ image: Case) {
        guard let outcome = Self.exercise(image.path) else { return }
        guard image.clean else { return }
        if case .unsupported = outcome { return }
        Issue.record("e2fsck finds \(image.image) clean, and it read as \(outcome)")
    }
}
