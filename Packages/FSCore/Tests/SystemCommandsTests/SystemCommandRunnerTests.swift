import Foundation
import MountKit
import SystemCommands
import Testing

/// The agent's runner (roadmap 0048): what a command printed and how it ended, never longer than its deadline plus the grace
/// period, and nothing it started left running.
struct SystemCommandRunnerTests {
    /// A deadline long past for the commands that finish, and short for the ones that must be stopped.
    static let quick = SystemCommandRunner(timeout: .seconds(1), grace: .milliseconds(500))

    @Test func aCommandsStatusAndBothStreamsAreReported() {
        let result = Self.quick.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result == CommandResult(status: 3, output: "out\nerr"))
    }

    @Test func aMissingExecutableIsReportedAsNotRun() {
        #expect(Self.quick.run("/nonexistent/tool", []).status == 127)
    }

    /// A hung `umount` of a dead server's mount must not hold an agent thread forever.
    @Test func aCommandPastItsDeadlineIsStoppedAndSaysSo() {
        let start = ContinuousClock.now
        let result = Self.quick.run("/bin/sleep", ["30"])
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect(result.output.contains("/bin/sleep did not finish within 1 seconds"))
    }

    /// A command that ignores SIGTERM is killed after the grace period, and so is what it started: a grandchild holding the
    /// output pipe would otherwise keep the runner waiting, and stay behind.
    @Test func aCommandIgnoringTerminationIsKilledWithItsChildren() throws {
        // The grandchild is a shell named by the marker (its `$0`), kept alive by its own sleep.
        let marker = "macfs-runner-test-\(UInt32.random(in: 0 ... .max))"
        let start = ContinuousClock.now
        let result = Self.quick.run(
            "/bin/sh",
            ["-c", "trap '' TERM; /bin/sh -c '/bin/sleep 30; :' \(marker) & wait; echo never"]
        )
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect(!result.output.contains("never"))
        Thread.sleep(forTimeInterval: 0.3)
        let left = Process()
        left.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        left.arguments = ["-f", marker]
        left.standardOutput = FileHandle.nullDevice
        try left.run()
        left.waitUntilExit()
        #expect(left.terminationStatus == 1, "pgrep found the grandchild still running")
    }

    /// The command is asked first: SIGTERM, which lets it clean up (here, write a file), before SIGKILL.
    @Test func aCommandPastItsDeadlineIsAskedToStopBeforeItIsKilled() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macfs-runner-\(UInt32.random(in: 0 ... .max))"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        let result = Self.quick.run(
            "/bin/sh",
            ["-c", "trap 'echo cleaned > \(file.path); exit 0' TERM; /bin/sleep 30 & wait"]
        )
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect((try? String(contentsOf: file, encoding: .utf8)) == "cleaned\n")
    }

    /// A command killed by a signal reports 128 plus the signal, as a shell does.
    @Test func aCommandKilledByASignalReportsItAsAShellDoes() {
        #expect(Self.quick.run("/bin/sh", ["-c", "kill -9 $$"]).status == 137)
    }

    /// Output is kept to its first `limit` bytes; the rest is read and dropped, so the command finishes and keeps its status.
    @Test func aChattyCommandKeepsItsStatusAndTheStartOfItsOutput() {
        let runner = SystemCommandRunner(timeout: .seconds(10), grace: .seconds(1), limit: 1000)
        let result = runner.run("/bin/sh", ["-c", "/usr/bin/yes | /usr/bin/head -c 5000000; exit 4"])
        #expect(result.status == 4)
        #expect(result.output.utf8.count <= 1000)
        #expect(result.output.hasPrefix("y\ny\n"))
    }
}
