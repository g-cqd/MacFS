public import AppSupport
import Foundation

/// Runs one scripted command of the installed app (`MacFS --mount-image`, `--unmount`, ...) and reads what it came to. The app
/// is launched through LaunchServices (`open`): run directly, it may not register its agent. `-n` starts a new instance beside any
/// open window. It writes its result to `resultFile`, which must be in its container; the launch waits up to `timeout` for it.
public struct AppLaunch: Sendable {
    let runner: any ProcessRunning
    let app: String
    let resultFile: String
    let timeout: Duration

    public init(runner: any ProcessRunning, app: String, resultFile: String, timeout: Duration = .seconds(60)) {
        self.runner = runner
        self.app = app
        self.resultFile = resultFile
        self.timeout = timeout
    }

    /// The result the app wrote, or nil when it could not be opened or wrote none.
    public func run(_ arguments: [String]) -> AutomationResult? {
        // A result left by an earlier run is not this one's.
        try? FileManager.default.removeItem(atPath: resultFile)
        defer { try? FileManager.default.removeItem(atPath: resultFile) }
        let opened = try? runner.run(
            Command("/usr/bin/open", ["-W", "-n", "-a", app, "--args"] + arguments + ["--result", resultFile])
        )
        // `open -W` cannot always wait for an app that exits at once: it returns 0 when the app is gone before LaunchServices
        // sees its pid, and fails ("Unable to block on applications ... kevent() ... No such process") when it is gone before
        // `open` watches it. Either way the app ran; any other failure means it did not.
        guard let opened, opened.status == 0 || opened.output.contains("Unable to block on application") else {
            return nil
        }
        // So the result may come after `open` returns: wait for it. The app writes it atomically, whole or not at all.
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            if let line = try? String(contentsOfFile: resultFile, encoding: .utf8) {
                return AutomationResult(line: line)
            }
            guard clock.now < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}
