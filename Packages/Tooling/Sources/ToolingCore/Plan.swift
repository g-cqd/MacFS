/// An ordered list of commands, printable before it is run (`--dry-run`).
public struct Plan: Sendable {
    public let steps: [Command]

    public init(steps: [Command]) {
        self.steps = steps
    }

    /// Runs every step even after a failure: a gate that fails must not hide the gates after it.
    public func execute(with runner: any ProcessRunning, dryRun: Bool) throws -> Report {
        var report = Report()
        for step in steps {
            report.lines.append(step.display)
            if dryRun { continue }
            if try runner.run(step).status != 0 { report.failed.append(step) }
        }
        return report
    }
}
