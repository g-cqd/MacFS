/// `swift test` output reduced to what a person acts on: compiler errors, issues, failures and totals.
public enum TestSummary {
    public static func reduce(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true).map { strip(String($0)) }.filter(keep)
    }

    private static func keep(_ line: String) -> Bool {
        if line.contains(": error:") { return true }
        if line.contains("recorded an issue") || line.contains(" failed after ") { return true }
        return line.contains("Test run with")
    }

    /// Removes ANSI colour sequences (`ESC [ ... m`).
    private static func strip(_ line: String) -> String {
        var result = ""
        var escaping = false
        for character in line {
            if escaping {
                if character == "m" { escaping = false }
                continue
            }
            if character == "\u{1B}" {
                escaping = true
                continue
            }
            result.append(character)
        }
        return result
    }
}
