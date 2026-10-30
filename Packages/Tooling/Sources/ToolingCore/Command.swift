import Foundation

/// One process to run: an absolute executable and its arguments. Never a shell string, so nothing is
/// re-parsed or globbed between the plan and the run.
public struct Command: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(_ executable: String, _ arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The command as a person would type it, quoting what a shell would split.
    public var display: String {
        ([executable] + arguments).map(Self.quote).joined(separator: " ")
    }

    private static func quote(_ word: String) -> String {
        let plain = word.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:+@%,".contains($0) }
        return plain && !word.isEmpty ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
