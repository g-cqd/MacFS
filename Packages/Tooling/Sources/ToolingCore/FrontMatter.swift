import AemiRegex
import Foundation

/// The `---`-fenced header of an ADR or roadmap entry: `key: value` lines, lists as `["0001", "0002"]`.
struct FrontMatter {
    private static let identifier = pattern("[0-9]{4}")

    let fields: [String: String]

    init?(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var fields: [String: String] = [:]
        for line in lines[1 ..< end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        self.fields = fields
    }

    /// The four-digit identifiers in a list field, or nil when the field is absent.
    func identifiers(_ key: String) -> [String]? {
        guard let value = fields[key] else { return nil }
        return Self.identifier.matches(in: value).map { String(value[$0.range(in: value)]) }
    }
}
