import AemiRegex

/// The documentation law of the white paper, as a check over `docs/` (path → contents).
public enum DocumentationLayout {
    private static let numbered = pattern("^[0-9]{4}-[a-z0-9-]+\\.md$")
    private static let diaryName = pattern("^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}\\.md$")
    private static let freeForm = ["docs/WHITE-PAPER.md", "docs/DESIGN.md"]

    public static func problems(_ tree: [String: String]) -> [String] {
        var problems: [String] = []
        var adrs: Entries = [:]
        var roadmap: Entries = [:]
        for (path, text) in tree.sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: "/").map(String.init)
            let name = parts.last ?? ""
            switch parts.count >= 3 ? parts[1] : "" {
                case "adr", "roadmap":
                    guard parts.count == 3, numbered.isMatch(in: name) else {
                        problems.append("\(path): name must be NNNN-title.md")
                        continue
                    }
                    let entry = (path, FrontMatter(text))
                    if parts[1] == "adr" {
                        adrs[String(name.prefix(4))] = entry
                    } else {
                        roadmap[String(name.prefix(4))] = entry
                    }
                case "diary":
                    if !diaryName.isMatch(in: name) { problems.append("\(path): name must be YYYY-MM-DD-NN.md") }
                    if lineCount(text) > 256 { problems.append("\(path) has \(lineCount(text)) lines (cap 256)") }
                case "research", "models":
                    continue
                default:
                    if path == "docs/WHITE-PAPER.md", lineCount(text) > 200 {
                        problems.append("WHITE-PAPER.md has \(lineCount(text)) lines (cap 200)")
                    } else if !freeForm.contains(path) {
                        problems.append("\(path): not in a documented place")
                    }
            }
        }
        problems += adrProblems(adrs) + roadmapProblems(roadmap)
        return problems
    }

    private typealias Entries = [String: (path: String, front: FrontMatter?)]

    /// Each entry in number order: a status from `statuses`, then the entry's own rules.
    private static func check(
        _ entries: Entries, statuses: [String],
        _ rules: (_ path: String, _ front: FrontMatter?, _ status: String) -> [String]
    ) -> [String] {
        var problems: [String] = []
        for (_, entry) in entries.sorted(by: { $0.key < $1.key }) {
            guard let status = entry.front?.fields["status"], statuses.contains(status) else {
                let choices = statuses.dropLast().joined(separator: ", ") + " or " + (statuses.last ?? "")
                problems.append("\(entry.path): status must be \(choices)")
                continue
            }
            problems += rules(entry.path, entry.front, status)
        }
        return problems
    }

    private static func adrProblems(_ adrs: Entries) -> [String] {
        check(adrs, statuses: ["accepted", "superseded"]) { path, front, status in
            var problems: [String] = []
            let number = String(path.split(separator: "/").last?.prefix(4) ?? "")
            for successor in front?.identifiers("superseded-by") ?? [] {
                let names = adrs[successor]?.front?.identifiers("supersedes") ?? []
                if !names.contains(number) {
                    problems.append("\(path): superseded by \(successor), which does not name it")
                }
            }
            if status == "superseded", (front?.identifiers("superseded-by") ?? []).isEmpty {
                problems.append("\(path): superseded without superseded-by")
            }
            return problems
        }
    }

    private static func roadmapProblems(_ entries: Entries) -> [String] {
        check(entries, statuses: ["open", "in-progress", "done"]) { path, front, status in
            guard let blockers = front?.identifiers("blocked-by") else { return ["\(path): no blocked-by"] }
            var problems: [String] = []
            for blocker in blockers where status != "done" {
                guard let other = entries[blocker] else {
                    problems.append("\(path): blocked by \(blocker), which does not exist")
                    continue
                }
                if other.front?.fields["status"] == "done" {
                    problems.append("\(path): blocked by \(blocker), which is done")
                }
            }
            return problems
        }
    }
}
