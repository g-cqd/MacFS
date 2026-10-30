import CryptoKit
import Foundation

/// A directory (a mounted volume) against a test image's manifest (`path<TAB>type<TAB>size<TAB>sha256-or-target`, from
/// Scripts/make-test-images.inner.sh): every node's type, every file's size and content, every link's target; nodes the
/// manifest lacks are problems unless `extra` names them (ext's `lost+found`). Symbolic links are not followed.
public enum TreeComparison {
    public static func problems(root: String, manifest: String, extra: Set<String>) throws -> [String] {
        var expected: [String: [String]] = [:]
        for line in manifest.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if columns.count == 4 { expected[columns[0]] = Array(columns.dropFirst()) }
        }
        let manager = FileManager.default
        var seen: Set<String> = []
        for path in manager.enumerator(atPath: root)?.compactMap({ $0 as? String }) ?? [] {
            seen.insert(path.precomposedStringWithCanonicalMapping)
        }
        var problems: [String] = []
        for (path, row) in expected.sorted(by: { $0.key < $1.key }) {
            guard seen.contains(path) else {
                problems.append("\(path): missing")
                continue
            }
            if let problem = try difference(root + "/" + path, row) { problems.append("\(path): \(problem)") }
        }
        for path in seen.sorted() where expected[path] == nil {
            let top = String(path.split(separator: "/").first ?? "")
            if !extra.contains(path), !extra.contains(top) { problems.append("\(path): not in the manifest") }
        }
        return problems
    }

    /// What differs between the node at `path` and its manifest row, or nil.
    private static func difference(_ path: String, _ row: [String]) throws -> String? {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let type = attributes[.type] as? FileAttributeType
        switch row[0] {
            case "dir":
                return type == .typeDirectory ? nil : "not a directory"
            case "link":
                guard type == .typeSymbolicLink else { return "not a link" }
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path)
                return target == row[2] ? nil : "link to \(target), not \(row[2])"
            default:
                guard type == .typeRegular else { return "not a file" }
                let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                guard String(size) == row[1] else { return "\(size) bytes, not \(row[1])" }
                let digest = try sha256(path)
                return digest == row[2] ? nil : "content differs"
        }
    }

    private static func sha256(_ path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
