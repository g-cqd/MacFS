import Foundation

/// Runs a command with `Process` and waits for it, its output captured. Blocks the calling thread: the mount service's callers
/// run it off any cooperative pool (Everest: a mount that waits on our own server must not park the pool that server needs).
public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return CommandResult(status: 127, output: "\(error)") }
        // before waiting: a full pipe would block the child
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
