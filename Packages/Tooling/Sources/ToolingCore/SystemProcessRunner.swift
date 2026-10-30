import Foundation

/// Runs a command with `Process`, its output streamed to ours as it comes.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ command: Command) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        try process.run()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: "")
    }
}
