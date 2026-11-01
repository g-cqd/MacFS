import MountKit
import SystemCommands

/// Runs a command through `SystemCommandRunner` (ADR-0017), never longer than `timeout`: its output streamed to ours as it comes,
/// or with `capture`, both streams merged as they were written and kept to their last `kept` bytes, where a build's error is.
/// Call it from a thread, not a task (`macfs-tool` has no `await`).
public struct SystemProcessRunner: ProcessRunning {
    /// The bytes of captured output kept: a build's last lines, and every listing the tooling reads whole.
    public static let kept = 1 << 18

    let capture: Bool
    let timeout: Duration

    public init(capture: Bool = false, timeout: Duration = .seconds(3600)) {
        self.capture = capture
        self.timeout = timeout
    }

    public func run(_ command: Command) throws -> ProcessResult {
        let runner = SystemCommandRunner(output: capture ? .last(Self.kept) : .passedThrough)
        let result = runner.run(command.executable, command.arguments, timeout: timeout)
        return ProcessResult(status: result.status, output: result.output)
    }
}
