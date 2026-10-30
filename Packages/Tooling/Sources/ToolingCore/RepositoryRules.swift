import AemiRegex
import Foundation

/// Reads the files a rule needs, keyed by path relative to the repository root.
public enum RepositoryFiles {
    public static func read(root: String, under directories: [String], suffix: String) throws -> [String: String] {
        var tree: [String: String] = [:]
        for directory in directories {
            let base = URL(fileURLWithPath: root).appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in walker where url.lastPathComponent.hasSuffix(suffix) {
                let relative = directory + url.path.dropFirst(base.path.count)
                tree[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return tree
    }
}

/// Lines as a text editor counts them.
func lineCount(_ text: String) -> Int {
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return text.hasSuffix("\n") ? parts - 1 : parts
}

/// A compiled pattern from a literal the authors wrote: one that does not compile is a bug here.
func pattern(_ source: String) -> Pattern {
    do { return try Pattern(source) } catch { preconditionFailure("pattern \(source): \(error)") }
}
