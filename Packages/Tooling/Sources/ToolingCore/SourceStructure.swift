import AemiRegex

/// One top-level type per file and at most 250 lines, over Swift sources (path → contents).
public enum SourceStructure {
    // A declaration at column 0, after attributes and modifiers: `public final class Name`.
    private static let declaration = pattern(
        "^(?:@[A-Za-z]+(?:\\([^)]*\\))? +)*(?:(?:public|package|internal|fileprivate|private|final|open|indirect|nonisolated) +)*"
            + "(?:struct|class|enum|protocol|actor) +([A-Za-z_][A-Za-z0-9_]*)"
    )

    public static func problems(_ tree: [String: String]) -> [String] {
        var problems: [String] = []
        for (path, text) in tree.sorted(by: { $0.key < $1.key }) {
            let lines = lineCount(text)
            if lines > 250 { problems.append("\(path) has \(lines) lines (cap 250)") }
            var names: [String] = []
            for line in text.split(separator: "\n") {
                guard let match = declaration.firstMatch(in: line), let range = match.range(ofGroup: 1, in: line) else {
                    continue
                }
                names.append(String(line[range]))
            }
            if names.count > 1 {
                problems.append("\(path) declares \(names.count) top-level types: \(names.joined(separator: ", "))")
            }
        }
        return problems
    }
}
