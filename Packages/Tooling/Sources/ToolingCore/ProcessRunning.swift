/// Runs commands. The one seam between the plans and the operating system, so tests run none.
public protocol ProcessRunning: Sendable {
    func run(_ command: Command) throws -> ProcessResult
}
