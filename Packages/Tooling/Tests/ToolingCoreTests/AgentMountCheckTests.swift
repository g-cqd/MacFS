import AppSupport
import Foundation
import Synchronization
import Testing
import ToolingCore

/// The agent path of the mount check (roadmap 0039): each image cloned into the app's container, mounted by the installed app
/// through its agent, compared with its manifest, refused a write, unmounted through the app, the clone removed. The runner and
/// the app's launches are fakes; nothing mounts.
@Suite struct AgentMountCheckTests {
    static let target = MountCheck.Target(image: "ext4", type: "ext", extra: ["lost+found"])
    static let container = "/Users/u/Library/Containers/dev.gcqd.MacFS/Data/tmp"

    final class Launches: Sendable {
        let made = Mutex<[[String]]>([])
        let answers: @Sendable ([String]) -> AutomationResult?
        init(_ answers: @escaping @Sendable ([String]) -> AutomationResult?) { self.answers = answers }
        func launch(_ arguments: [String]) -> AutomationResult? {
            made.withLock { $0.append(arguments) }
            return answers(arguments)
        }
    }

    final class Compared: Sendable {
        let seen = Mutex<[String]>([])
    }

    static func mounted(_ arguments: [String]) -> AutomationResult? {
        arguments.first == "--mount-image" ? .mounted(id: "R1", mountPoint: "/agent/Mounts/agentcheck-ext4") : .done
    }

    func check(
        _ launches: Launches,
        _ runner: RecordingRunner = RecordingRunner(),
        compared: Compared = Compared(),
        problems: [String] = [],
        refused: Bool = true
    ) -> AgentMountCheck {
        AgentMountCheck(
            runner: runner,
            root: "/repo",
            container: Self.container,
            launch: launches.launch,
            verification: MountVerification(
                compare: { point, manifest, extra in
                    compared.seen.withLock { $0.append("\(point) \(manifest) \(extra.sorted())") }
                    return problems
                },
                writeRefused: { _ in refused }
            )
        )
    }

    @Test func anImageIsClonedMountedComparedAndReleased() {
        let runner = RecordingRunner()
        let launches = Launches(Self.mounted)
        let compared = Compared()
        let outcome = check(launches, runner, compared: compared).run(Self.target)
        #expect(outcome.problems.isEmpty)
        let clone = "\(Self.container)/agentcheck-ext4.img"
        let commands = runner.commands.withLock { $0 }
        #expect(
            commands.first == Command("/bin/cp", ["-c", "/repo/TestImages/ext4.img", clone]),
            "an APFS clone: no copy"
        )
        #expect(commands.last == Command("/bin/rm", ["-f", clone]))
        #expect(launches.made.withLock { $0 } == [["--mount-image", clone], ["--unmount", "R1"]])
        #expect(
            compared.seen.withLock { $0 } == [
                "/agent/Mounts/agentcheck-ext4 /repo/TestImages/ext4.manifest [\"lost+found\"]"
            ]
        )
    }

    @Test func differencesAndAWriteAreProblemsAndTheMountStillGoes() {
        let launches = Launches(Self.mounted)
        let outcome = check(launches, problems: ["missing: a.txt"], refused: false).run(Self.target)
        #expect(outcome.problems == ["missing: a.txt", "a write was accepted on a read-only mount"])
        #expect(launches.made.withLock { $0 }.last == ["--unmount", "R1"])
    }

    /// The app's own error, no answer at all, or an answer that is not one: a problem, nothing compared, the clone removed.
    @Test(
        arguments: [
            (.failed("the agent did not answer"), "mount: the agent did not answer"),
            (nil, "mount: MacFS gave no result (is it installed in /Applications, its agent registered?)"),
            (.done, "mount: MacFS answered ok without a mount")
        ] as [(AutomationResult?, String)]
    )
    func aMountThatFailsIsReported(_ answer: AutomationResult?, _ problem: String) {
        let runner = RecordingRunner()
        let compared = Compared()
        let launches = Launches { $0.first == "--mount-image" ? answer : .done }
        let outcome = check(launches, runner, compared: compared).run(Self.target)
        #expect(outcome.problems == [problem])
        #expect(compared.seen.withLock { $0 }.isEmpty)
        #expect(launches.made.withLock { $0 }.count == 1, "nothing to unmount")
        #expect(runner.commands.withLock { $0 }.last?.executable == "/bin/rm")
    }

    @Test func anUnmountThatFailsIsReported() {
        let launches = Launches { $0.first == "--mount-image" ? Self.mounted($0) : .failed("busy") }
        #expect(check(launches).run(Self.target).problems == ["unmount: busy"])
    }

    @Test func aCloneThatFailsStopsThere() {
        let runner = RecordingRunner {
            $0.executable == "/bin/cp"
                ? ProcessResult(status: 1, output: "no space") : ProcessResult(status: 0, output: "")
        }
        let launches = Launches(Self.mounted)
        #expect(check(launches, runner).run(Self.target).problems == ["clone: no space"])
        #expect(launches.made.withLock { $0 }.isEmpty)
    }
}

/// Launching the installed app for one command: `open -W -n` (wait for it, a new instance beside any window), `--result` naming a
/// file in its container, read back and removed.
@Suite struct AppLaunchTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("applaunch-\(UUID().uuidString)").path

    func file(_ name: String) -> String {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory + "/" + name
    }

    @Test func theAppIsOpenedAndWaitedForAndItsResultRead() {
        let result = file("result.txt")
        let runner = RecordingRunner { _ in
            try? "ok\tR1\t/m/x\n".write(toFile: result, atomically: true, encoding: .utf8)
            return ProcessResult(status: 0, output: "")
        }
        let launch = AppLaunch(runner: runner, app: "/Applications/MacFS.app", resultFile: result)
        #expect(launch.run(["--mount-image", "/c/x.img"]) == .mounted(id: "R1", mountPoint: "/m/x"))
        #expect(
            runner.commands.withLock { $0 } == [
                Command(
                    "/usr/bin/open",
                    [
                        "-W", "-n", "-a", "/Applications/MacFS.app", "--args", "--mount-image", "/c/x.img", "--result",
                        result
                    ]
                )
            ]
        )
        #expect(!FileManager.default.fileExists(atPath: result), "read once, then removed")
    }

    /// `open -W` cannot wait for an app that exits before LaunchServices sees its pid ("Unable to block on application"): it
    /// returns 0 at once, and the result is written after. The launch waits for the result itself.
    @Test func aResultWrittenAfterOpenReturnsIsWaitedFor() {
        let result = file("result.txt")
        let runner = RecordingRunner { _ in
            DispatchQueue.global()
                .asyncAfter(deadline: .now() + .milliseconds(300)) {
                    try? "ok\n".write(toFile: result, atomically: true, encoding: .utf8)
                }
            return ProcessResult(status: 0, output: "Unable to block on application")
        }
        let launch = AppLaunch(runner: runner, app: "/A.app", resultFile: result, timeout: .seconds(5))
        #expect(launch.run(["--unmount", "R1"]) == .done)
    }

    /// When the app exits between `open` finding its pid and watching it, `open` fails (status 1, "initial call to kevent()
    /// failed: No such process"), and yet the app ran: its result is still read.
    @Test func anAppThatExitedBeforeOpenWatchedItStillGivesItsResult() {
        let result = file("result.txt")
        let runner = RecordingRunner { _ in
            try? "ok\n".write(toFile: result, atomically: true, encoding: .utf8)
            return ProcessResult(
                status: 1,
                output: "Unable to block on applications (initial call to kevent() failed: No such process)\n"
            )
        }
        let launch = AppLaunch(runner: runner, app: "/A.app", resultFile: result, timeout: .seconds(5))
        #expect(launch.run(["--unmount", "R1"]) == .done)
    }

    /// A result left by an earlier run is not this run's: it is removed before the launch.
    @Test func aStaleResultIsNotRead() {
        let result = file("result.txt")
        try? "ok\n".write(toFile: result, atomically: true, encoding: .utf8)
        let launch = AppLaunch(
            runner: RecordingRunner(),
            app: "/A.app",
            resultFile: result,
            timeout: .milliseconds(200)
        )
        #expect(launch.run(["--unmount", "R1"]) == nil)
    }

    @Test func anAppThatCannotBeOpenedGivesNoResult() {
        let result = file("result.txt")
        let runner = RecordingRunner { _ in
            try? "ok\n".write(toFile: result, atomically: true, encoding: .utf8)
            return ProcessResult(status: 1, output: "Unable to find application")
        }
        #expect(AppLaunch(runner: runner, app: "/A.app", resultFile: result).run(["--unmount", "R1"]) == nil)
    }
}
