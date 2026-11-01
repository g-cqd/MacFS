import Foundation
import Synchronization
import Testing
import ToolingCore

/// `macfs-tool mounts` (roadmap 0025): each test image attached, mounted through its FSKit module, compared with its manifest,
/// refused a write, unmounted and detached. The sequence runs on a recording runner; the comparison on a real directory.
@Suite struct MountCheckTests {
    static let attachOutput = "/dev/disk42          \t                               \t\n"
    static let target = MountCheck.Target(image: "ext4", type: "ext4", extra: ["lost+found"])

    static func check(
        _ runner: RecordingRunner,
        problems: [String] = [],
        refused: Bool = true
    ) -> MountCheck {
        MountCheck(
            runner: runner,
            root: "/repo",
            mountPoint: { "/tmp/mounts/\($0.image)" },
            verification: MountVerification(compare: { _, _, _ in problems }, writeRefused: { _ in refused })
        )
    }

    static func runner(failing executable: String? = nil, failingArgument: String? = nil) -> RecordingRunner {
        RecordingRunner { command in
            if command.executable == executable, failingArgument.map(command.arguments.contains) ?? true {
                return ProcessResult(status: 1, output: "failed")
            }
            return ProcessResult(status: 0, output: command.arguments.first == "attach" ? attachOutput : "")
        }
    }

    @Test func aGoodVolumeIsAttachedMountedComparedAndReleased() throws {
        let runner = Self.runner()
        let outcome = Self.check(runner).run(Self.target)
        #expect(outcome.problems == [])
        let commands = runner.commands.withLock { $0 }
        #expect(
            commands == [
                Command("/usr/bin/hdiutil", ["attach", "-nomount", "-readonly", "/repo/TestImages/ext4.img"]),
                Command("/sbin/mount", ["-F", "-t", "ext4", "-o", "rdonly", "/dev/disk42", "/tmp/mounts/ext4"]),
                Command("/sbin/umount", ["/tmp/mounts/ext4"]),
                Command("/usr/bin/hdiutil", ["detach", "/dev/disk42"])
            ]
        )
    }

    @Test func aFailedMountStillDetaches() {
        let runner = Self.runner(failing: "/sbin/mount")
        let outcome = Self.check(runner).run(Self.target)
        #expect(outcome.problems.count == 1 && outcome.problems[0].contains("mount"))
        #expect(runner.executables.last == "/usr/bin/hdiutil")
        #expect(runner.commands.withLock { $0.last?.arguments.first } == "detach")
        #expect(!runner.executables.contains("/sbin/umount"), "nothing to unmount")
    }

    @Test func anAttachWithoutADeviceStopsThere() {
        let runner = RecordingRunner { _ in ProcessResult(status: 0, output: "no device here") }
        let outcome = Self.check(runner).run(Self.target)
        #expect(outcome.problems.count == 1)
        #expect(runner.commands.withLock { $0.count } == 1)
    }

    @Test func differencesAndAnAcceptedWriteAreProblemsAndTheVolumeIsStillReleased() {
        let runner = Self.runner()
        let outcome = Self.check(runner, problems: ["a.txt: wrong content"], refused: false).run(Self.target)
        #expect(outcome.problems.contains("a.txt: wrong content"))
        #expect(outcome.problems.contains { $0.contains("write") })
        #expect(runner.executables.suffix(2) == ["/sbin/umount", "/usr/bin/hdiutil"])
    }

    @Test func everyTestImageWithAModuleIsChecked() {
        let images = MountCheck.targets.map(\.image)
        for image in ["ext2", "ext4", "ext4-inline", "btrfs", "btrfs-zlib", "btrfs-lzo", "ntfs"] {
            #expect(images.contains(image), "\(image)")
        }
        #expect(MountCheck.targets.first { $0.image == "ntfs" }?.type == "ntfsro")
        #expect(MountCheck.targets.filter { $0.type == "ext4" }.allSatisfy { $0.extra == ["lost+found"] })
    }

    // MARK: The comparison, on a real directory

    static func tree(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mount-check-\(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dir"),
            withIntermediateDirectories: true
        )
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("hello.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("dir/link").path,
            withDestinationPath: "../hello.txt"
        )
        try build(root)
        return root
    }

    static let manifest = """
        dir\tdir\t0\t-
        dir/link\tlink\t0\t../hello.txt
        hello.txt\tfile\t6\t5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03

        """

    @Test func aMatchingTreeHasNoProblems() throws {
        let root = try Self.tree { _ in }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try TreeComparison.problems(root: root.path, manifest: Self.manifest, extra: []) == [])
    }

    @Test func eachDifferenceIsNamed() throws {
        let root = try Self.tree { root in
            try Data("HELLO\n".utf8).write(to: root.appendingPathComponent("hello.txt"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("dir/link"))
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent("dir/link").path,
                withDestinationPath: "elsewhere"
            )
            try Data().write(to: root.appendingPathComponent("stray"))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("lost+found"),
                withIntermediateDirectories: false
            )
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let problems = try TreeComparison.problems(root: root.path, manifest: Self.manifest, extra: ["lost+found"])
        #expect(problems.contains { $0.hasPrefix("hello.txt") })
        #expect(problems.contains { $0.hasPrefix("dir/link") })
        #expect(problems.contains("stray: not in the manifest"))
        #expect(!problems.contains { $0.hasPrefix("lost+found") }, "an expected extra is not a problem")
        #expect(problems.count == 3)
    }

    @Test func aWritableDirectoryDoesNotRefuseAWriteAndLeavesNoProbe() throws {
        let root = try Self.tree { _ in }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!MountCheck.refusesWrites(at: root.path))
        #expect(try TreeComparison.problems(root: root.path, manifest: Self.manifest, extra: []) == [])
    }

    @Test func aReadOnlyDirectoryRefusesAWrite() throws {
        let root = try Self.tree { _ in }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        #expect(MountCheck.refusesWrites(at: root.path))
    }

    @Test func aMissingNodeIsAProblem() throws {
        let root = try Self.tree { root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("hello.txt"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            try TreeComparison.problems(root: root.path, manifest: Self.manifest, extra: []) == ["hello.txt: missing"]
        )
    }
}

/// The system runner (roadmap 0048): captured, both streams merged as they were written and kept to their end, where a build's
/// error is; never longer than its deadline. Called from a thread of its own, as `macfs-tool` calls it.
@Suite struct SystemProcessRunnerTests {
    static func run(_ runner: SystemProcessRunner, _ command: Command) async -> ProcessResult? {
        await withCheckedContinuation { finished in
            Thread.detachNewThread { finished.resume(returning: try? runner.run(command)) }
        }
    }

    @Test func capturedOutputIsKeptWithBothStreamsInOrder() async {
        let result = await Self.run(
            SystemProcessRunner(capture: true),
            Command("/bin/sh", ["-c", "echo /dev/disk9; echo warning >&2; echo done"])
        )
        #expect(result == ProcessResult(status: 0, output: "/dev/disk9\nwarning\ndone"))
    }

    @Test func aLongCapturedOutputKeepsItsEnd() async {
        let result = await Self.run(
            SystemProcessRunner(capture: true),
            Command("/bin/sh", ["-c", "/usr/bin/yes | /usr/bin/head -c 20000000; echo '** BUILD FAILED **'; exit 65"])
        )
        #expect(result?.status == 65)
        #expect(result?.output.hasSuffix("y\n** BUILD FAILED **") == true)
        #expect((result?.output.utf8.count ?? .max) <= SystemProcessRunner.kept)
    }

    @Test func aCommandPastItsDeadlineIsStopped() async {
        let start = ContinuousClock.now
        let result = await Self.run(
            SystemProcessRunner(capture: true, timeout: .seconds(1)),
            Command("/bin/sleep", ["30"])
        )
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(result?.status == 124)
    }
}
