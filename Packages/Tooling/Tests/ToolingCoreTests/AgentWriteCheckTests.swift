import AppSupport
import Synchronization
import Testing
import ToolingCore

/// The agent's writable path (roadmap 0046): a fresh copy in the app's container, mounted writable by the installed app
/// through its agent (`--mount-image PATH --writable`), changed by the write check's operations, unmounted through the app,
/// then judged on Linux.
@Suite struct AgentWriteCheckTests {
    static let target = WriteCheck.Target(image: "ext2", type: "ext4", identityOffset: 1024 + 0x68)
    static let workspace = WriteCheck.Workspace(
        image: "/c/write-ext2/ext2.img",
        payload: "/c/write-ext2/payload.bin",
        point: "/c/write-ext2/point",
        expected: ["/hard.bin": "aa"]
    )

    final class Launches: Sendable {
        let calls = Mutex<[[String]]>([])
        let checked = Mutex<[String]>([])
        var all: [[String]] { calls.withLock { $0 } }
    }

    static func check(
        _ runner: RecordingRunner,
        _ launches: Launches,
        mount: AutomationResult? = .mounted(id: "r1", mountPoint: "/c/Mounts/ext2"),
        verdict: [String] = []
    ) -> AgentWriteCheck {
        AgentWriteCheck(
            runner: runner,
            launch: { arguments in
                launches.calls.withLock { $0.append(arguments) }
                return arguments.first == "--mount-image" ? mount : .done
            },
            checker: { _, image, _ in
                launches.checked.withLock { $0.append(image) }
                return verdict
            }
        )
    }

    @Test func aWritableAgentMountIsChangedUnmountedThenChecked() {
        let runner = RecordingRunner()
        let launches = Launches()
        let outcome = Self.check(runner, launches).run(Self.target, in: Self.workspace)
        #expect(outcome.problems == [])
        #expect(launches.all == [["--mount-image", "/c/write-ext2/ext2.img", "--writable"], ["--unmount", "r1"]])
        #expect(
            runner.commands.withLock { $0 }
                == WriteCheck.operations(point: "/c/Mounts/ext2", payload: "/c/write-ext2/payload.bin")
        )
        #expect(launches.checked.withLock { $0 } == ["/c/write-ext2/ext2.img"])
    }

    @Test func aRefusedMountChangesAndChecksNothing() {
        let runner = RecordingRunner()
        let launches = Launches()
        let outcome = Self.check(runner, launches, mount: .failed("no agent")).run(Self.target, in: Self.workspace)
        #expect(outcome.problems == ["mount: no agent"])
        #expect(runner.commands.withLock { $0 }.isEmpty)
        #expect(launches.checked.withLock { $0 }.isEmpty)
    }

    @Test func aFailedOperationStillUnmountsAndChecks() {
        let runner = RecordingRunner { command in
            ProcessResult(status: command.executable == "/bin/mkdir" ? 1 : 0, output: "")
        }
        let launches = Launches()
        let outcome = Self.check(runner, launches, verdict: ["e2fsck: 4"]).run(Self.target, in: Self.workspace)
        #expect(outcome.problems.first?.contains("/bin/mkdir") == true && outcome.problems.last == "e2fsck: 4")
        #expect(launches.all.last == ["--unmount", "r1"])
    }
}
