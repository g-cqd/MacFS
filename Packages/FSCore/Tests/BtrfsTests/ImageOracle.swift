import CryptoKit
import FSCore
import Foundation
import Testing

/// Compares a reader's whole tree with the manifest the Linux tools wrote (Scripts/make-test-images.sh).
enum ImageOracle {
    struct Row: Equatable {
        let type: String
        let size: UInt64
        /// SHA-256 for files, the target for links, "-" for directories.
        let detail: String
    }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestImages")

    static func image(_ name: String) throws -> FileBlockSource {
        let path = directory.appendingPathComponent("\(name).img").path
        guard FileManager.default.fileExists(atPath: path) else {
            Issue.record("missing \(path): run Scripts/make-test-images.sh")
            throw DiskError.notFound
        }
        return try FileBlockSource(path: path)
    }

    static func manifest(_ name: String) throws -> [String: Row] {
        let text = try String(contentsOf: directory.appendingPathComponent("\(name).manifest"), encoding: .utf8)
        var rows: [String: Row] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            rows[fields[0]] = Row(type: fields[1], size: UInt64(fields[2]) ?? 0, detail: fields[3])
        }
        return rows
    }

    /// Reads every file in `chunk`-byte pieces (so reads cross extent and run boundaries) and hashes it.
    static func observed(_ fileSystem: any ReadOnlyFileSystem, chunk: Int = 65_536 + 513) throws -> [String: Row] {
        var rows: [String: Row] = [:]
        try TreeWalk.visit(fileSystem, pageSize: 7) { (visit) throws(DiskError) in
            let attributes = try fileSystem.attributes(of: visit.entry.id)
            switch visit.entry.kind {
                case .directory:
                    rows[visit.path] = Row(type: "dir", size: 0, detail: "-")
                case .symlink:
                    let target = String(decoding: try fileSystem.readLink(visit.entry.id), as: UTF8.self)
                    rows[visit.path] = Row(type: "link", size: 0, detail: target)
                default:
                    var hash = SHA256()
                    var offset: UInt64 = 0
                    while offset < attributes.size {
                        let bytes = try fileSystem.read(visit.entry.id, at: offset, count: chunk)
                        guard !bytes.isEmpty else { throw .corrupt("short read at \(offset) of \(visit.path)") }
                        hash.update(data: bytes)
                        offset += UInt64(bytes.count)
                    }
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    rows[visit.path] = Row(type: "file", size: attributes.size, detail: digest)
            }
        }
        return rows
    }

    /// `extra` names paths the format adds on its own (ext's `lost+found`); they must be present.
    static func expectMatch(_ fileSystem: any ReadOnlyFileSystem, manifest name: String, extra: Set<String> = []) throws
    {
        let expected = try manifest(name)
        var actual = try observed(fileSystem)
        for path in extra { #expect(actual.removeValue(forKey: path) != nil, "\(name): \(path) is missing") }
        for (path, row) in expected where actual[path] != row {
            Issue.record("\(name): \(path) expected \(row), read \(String(describing: actual[path]))")
        }
        for path in actual.keys where expected[path] == nil { Issue.record("\(name): unexpected \(path)") }
        #expect(expected.count > 300, "a manifest this small cannot be the generated one")
        #expect(expected.count == actual.count)
    }
}
