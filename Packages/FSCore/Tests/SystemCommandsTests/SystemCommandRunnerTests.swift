import Dispatch
import Foundation
import MountKit
import Testing

@testable import SystemCommands

/// The agent's runner (roadmap 0048): what a command printed and how it ended, never longer than its deadline plus the grace
/// period, and nothing it started left running.
struct SystemCommandRunnerTests {
    /// A deadline long past for the commands that finish, and short for the ones that must be stopped.
    static let quick = Quick()

    struct Quick {
        let runner = SystemCommandRunner(grace: .milliseconds(500))
        func runOffThePool(_ executable: String, _ arguments: [String]) async -> CommandResult {
            await runner.runOffThePool(executable, arguments, timeout: .seconds(1))
        }
    }

    /// `run` blocks its thread while the command's task needs one of the pool's: called from a task, it would starve the pool
    /// (all of this suite's tests at once, each blocking a pool thread, timed out commands that had finished). Refused, loudly.
    @Test func aCallFromATaskIsRefused() async {
        let result = SystemCommandRunner().run("/bin/echo", ["x"], timeout: .seconds(1))
        #expect(result.status == SystemCommandRunner.notRun)
        #expect(result.output.contains("was not run: called from a task"))
    }

    @Test func aCommandsStatusAndBothStreamsAreReported() async {
        let result = await Self.quick.runOffThePool("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result == CommandResult(status: 3, output: "out\nerr"))
    }

    @Test func aMissingExecutableIsReportedAsNotRun() async {
        #expect(await Self.quick.runOffThePool("/nonexistent/tool", []).status == 127)
    }

    /// A hung `umount` of a dead server's mount must not hold an agent thread forever.
    @Test func aCommandPastItsDeadlineIsStoppedAndSaysSo() async {
        let start = ContinuousClock.now
        let result = await Self.quick.runOffThePool("/bin/sleep", ["30"])
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect(result.output.contains("/bin/sleep did not finish within 1 seconds"))
    }

    /// A command that ignores SIGTERM is killed after the grace period, and so is what it started: a grandchild holding the
    /// output pipe would otherwise keep the runner waiting, and stay behind.
    @Test func aCommandIgnoringTerminationIsKilledWithItsChildren() async throws {
        // The grandchild is a shell named by the marker (its `$0`), kept alive by its own sleep.
        let marker = "macfs-runner-test-\(UInt32.random(in: 0 ... .max))"
        let start = ContinuousClock.now
        let result = await Self.quick.runOffThePool(
            "/bin/sh",
            ["-c", "trap '' TERM; /bin/sh -c '/bin/sleep 30; :' \(marker) & wait; echo never"]
        )
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect(!result.output.contains("never"))
        try await Task.sleep(for: .milliseconds(300))
        let left = Process()
        left.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        left.arguments = ["-f", marker]
        left.standardOutput = FileHandle.nullDevice
        try left.run()
        left.waitUntilExit()
        #expect(left.terminationStatus == 1, "pgrep found the grandchild still running")
    }

    /// A command that does not end after its SIGKILL cannot hold the caller. Live, a `umount` stuck in the kernel on a frozen
    /// NFS server outlived its deadline by 6.6 s; here the command's work ignores cancellation, as such a process ignores its
    /// signals. The call returns one second after the grace period at most; the command is reaped in the background.
    @Test func aCommandThatDoesNotEndAfterItsKillDoesNotHoldTheCaller() async {
        let runner = SystemCommandRunner(grace: .milliseconds(500)) { _, _ in
            await withCheckedContinuation { finished in
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { finished.resume() }
            }
            return CommandResult(status: 0, output: "")
        }
        let start = ContinuousClock.now
        let result = await runner.runOffThePool("/sbin/umount", ["/stuck"], timeout: .seconds(1))
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect(
            result.output
                == "/sbin/umount did not finish within 1 seconds, nor end after SIGKILL; it is reaped when it does"
        )
    }

    /// A build's error is at its end: `.last` keeps the end of both streams merged as they were written, and the status.
    @Test func theLastPolicyKeepsTheEndOfBothStreamsInOrder() async {
        let runner = SystemCommandRunner(grace: .seconds(1), output: .last(1000))
        let result = await runner.runOffThePool(
            "/bin/sh",
            ["-c", "/usr/bin/yes | /usr/bin/head -c 5000000; echo error >&2; echo '** BUILD FAILED **'; exit 65"],
            timeout: .seconds(10)
        )
        #expect(result.status == 65)
        #expect(result.output.utf8.count <= 1000)
        #expect(result.output.hasSuffix("y\nerror\n** BUILD FAILED **"))
    }

    /// `.passedThrough` gives the command our own streams (the gates, as they run): nothing kept, the status reported, and
    /// still a deadline.
    @Test func thePassedThroughPolicyKeepsNothingButTheStatusAndTheDeadline() async {
        let runner = SystemCommandRunner(grace: .milliseconds(500), output: .passedThrough)
        #expect(
            await runner.runOffThePool("/bin/sh", ["-c", "echo through; exit 5"], timeout: .seconds(5))
                == CommandResult(status: 5, output: "")
        )
        let start = ContinuousClock.now
        #expect(
            await runner.runOffThePool("/bin/sleep", ["30"], timeout: .seconds(1)).status
                == SystemCommandRunner.timedOut
        )
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    /// What a passed-through command prints reaches our own standard output: observed in a child process, whose output the
    /// exit test captures.
    @Test func aPassedThroughCommandPrintsToOurOutput() async {
        let child = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let runner = SystemCommandRunner(output: .passedThrough)
            let result = await runner.runOffThePool("/bin/echo", ["passed through"], timeout: .seconds(5))
            exit(result.status == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        let printed = String(decoding: child.map(\.standardOutputContent) ?? [], as: UTF8.self)
        #expect(printed.contains("passed through"))
    }

    /// The tail holds at most twice its limit, whatever it is fed, and gives back exactly the last bytes.
    @Test func theTailStaysBoundedAndKeepsTheLastBytes() {
        var tail = Tail(limit: 10)
        var all: [UInt8] = []
        for chunk in [3, 25, 1, 7, 40, 2] {
            let bytes = (0 ..< chunk).map { UInt8(truncatingIfNeeded: all.count + $0) }
            all += bytes
            tail.append(bytes)
            #expect(tail.held.count <= 20)
            #expect(tail.bytes == Array(all.suffix(10)))
        }
    }

    /// Waits keep their fractions of a second: the grace period is often one.
    @Test func aDurationBecomesTheSameDispatchInterval() async {
        #expect(Duration.milliseconds(1500).dispatch == .nanoseconds(1_500_000_000))
        #expect(Duration.seconds(10).dispatch == .nanoseconds(10_000_000_000))
    }

    /// The command is asked first: SIGTERM, which lets it clean up (here, write a file), before SIGKILL.
    @Test func aCommandPastItsDeadlineIsAskedToStopBeforeItIsKilled() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macfs-runner-\(UInt32.random(in: 0 ... .max))"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await Self.quick.runOffThePool(
            "/bin/sh",
            ["-c", "trap 'echo cleaned > \(file.path); exit 0' TERM; /bin/sleep 30 & wait"]
        )
        #expect(result.status == SystemCommandRunner.timedOut)
        #expect((try? String(contentsOf: file, encoding: .utf8)) == "cleaned\n")
    }

    /// A command killed by a signal reports 128 plus the signal, as a shell does.
    @Test func aCommandKilledByASignalReportsItAsAShellDoes() async {
        #expect(await Self.quick.runOffThePool("/bin/sh", ["-c", "kill -9 $$"]).status == 137)
    }

    /// Output is kept to its first `limit` bytes; the rest is read and dropped, so the command finishes and keeps its status.
    @Test func aChattyCommandKeepsItsStatusAndTheStartOfItsOutput() async {
        let runner = SystemCommandRunner(grace: .seconds(1), output: .first(1000))
        let result = await runner.runOffThePool(
            "/bin/sh",
            ["-c", "/usr/bin/yes | /usr/bin/head -c 5000000; exit 4"],
            timeout: .seconds(10)
        )
        #expect(result.status == 4)
        #expect(result.output.utf8.count <= 1000)
        #expect(result.output.hasPrefix("y\ny\n"))
    }
}

extension SystemCommandRunner {
    /// `run` from a thread of its own, as the agent calls it from its XPC queue; the test's task waits without blocking.
    func runOffThePool(_ executable: String, _ arguments: [String], timeout: Duration) async -> CommandResult {
        await withCheckedContinuation { finished in
            Thread.detachNewThread { finished.resume(returning: run(executable, arguments, timeout: timeout)) }
        }
    }
}
