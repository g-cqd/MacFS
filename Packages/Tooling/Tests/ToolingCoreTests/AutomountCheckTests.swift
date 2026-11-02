import Synchronization
import Testing
import ToolingCore

/// The automount stays read-only (ADR-0018, roadmap 0046): once the modules had a check, Disk Arbitration automounted a
/// writable ext2 image read-write until writes had to be asked for by name. A copy is attached the ordinary way, its mount
/// must refuse a write, and it is detached whatever happened.
@Suite struct AutomountCheckTests {
    static let attachOutput = "/dev/disk42          \t                               \t/Volumes/ext2 1\n"

    static func runner(_ output: String = attachOutput) -> RecordingRunner {
        RecordingRunner { command in
            ProcessResult(status: 0, output: command.arguments.first == "attach" ? output : "")
        }
    }

    @Test func aReadOnlyAutomountPassesAndIsDetached() {
        let runner = Self.runner()
        let check = AutomountCheck(runner: runner) { point in point == "/Volumes/ext2 1" }
        #expect(check.run(image: "/tmp/w/ext2.img") == [])
        #expect(
            runner.commands.withLock { $0 } == [
                Command("/usr/bin/hdiutil", ["attach", "/tmp/w/ext2.img"]),
                Command("/usr/bin/hdiutil", ["detach", "/dev/disk42"])
            ]
        )
    }

    @Test func aWritableAutomountIsAProblem() {
        let runner = Self.runner()
        let problems = AutomountCheck(runner: runner) { _ in false }.run(image: "/tmp/w/ext2.img")
        #expect(problems.count == 1 && problems[0].contains("accepted a write"))
        #expect(runner.executables.last == "/usr/bin/hdiutil")
    }

    @Test func noAutomountIsAProblemAndStillDetaches() {
        let runner = Self.runner("/dev/disk42          \t                               \t\n")
        let problems = AutomountCheck(runner: runner) { _ in true }.run(image: "/tmp/w/ext2.img")
        #expect(problems.count == 1 && problems[0].contains("not mounted"))
        #expect(runner.commands.withLock { $0.last } == Command("/usr/bin/hdiutil", ["detach", "/dev/disk42"]))
    }
}
