import Foundation

/// Runs a command with `Process`, its output streamed to ours as it comes, or with `capture`, its standard output kept for the
/// caller, standard error with it (a failure then says why).
public struct SystemProcessRunner: ProcessRunning {
    let capture: Bool

    public init(capture: Bool = false) { self.capture = capture }

    public func run(_ command: Command) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        let pipe = Pipe()
        if capture {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        try process.run()
        // Read before waiting: a full pipe would block the child forever.
        let output = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}
