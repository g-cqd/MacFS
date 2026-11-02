import Foundation
import Synchronization
import Testing
import ToolingCore

/// The live write check (roadmap 0046): a copy of a test image with its own volume identity, attached writable, mounted through
/// its FSKit module without `rdonly`, changed in every way the writer supports by commands with deadlines, unmounted, detached,
/// then judged by the format's own checker. The sequence runs on a recording runner; the copy on real files.
@Suite struct WriteCheckTests {
    static let attachOutput = "/dev/disk42          \t                               \t\n"
    static let target = WriteCheck.Target(image: "ext2", type: "ext4", identityOffset: 1024 + 0x68)
    static let workspace = WriteCheck.Workspace(
        image: "/tmp/w/ext2.img",
        payload: "/tmp/w/payload.bin",
        point: "/tmp/w/point",
        expected: ["/renamed/moved.bin": "aa", "/short.bin": "bb"]
    )

    static func runner(failing executable: String? = nil) -> RecordingRunner {
        RecordingRunner { command in
            if command.executable == executable { return ProcessResult(status: 1, output: "failed") }
            return ProcessResult(status: 0, output: command.arguments.first == "attach" ? attachOutput : "")
        }
    }

    /// The checker's calls.
    final class Checked: Sendable {
        let calls = Mutex<[String]>([])
        var list: [String] { calls.withLock { $0 } }
    }

    static func check(_ runner: RecordingRunner, checked: Checked, verdict: [String] = []) -> WriteCheck {
        WriteCheck(
            runner: runner,
            pause: { _ in },
            checker: { target, image, expected in
                checked.calls.withLock { $0.append("\(target.image) \(image) \(expected.keys.sorted())") }
                return verdict
            }
        )
    }

    @Test func aGoodSessionAttachesWritableMountsChangesReleasesThenChecks() {
        let runner = Self.runner()
        let checked = Checked()
        let outcome = Self.check(runner, checked: checked).run(Self.target, in: Self.workspace)
        #expect(outcome.problems == [])
        let commands = runner.commands.withLock { $0 }
        let operations = WriteCheck.operations(point: "/tmp/w/point", payload: "/tmp/w/payload.bin")
        #expect(
            commands
                == [
                    Command("/usr/bin/hdiutil", ["attach", "-nomount", "/tmp/w/ext2.img"]),
                    Command("/sbin/mount", ["-F", "-t", "ext4", "-o", "rw", "/dev/disk42", "/tmp/w/point"])
                ] + operations + [
                    Command("/sbin/umount", ["/tmp/w/point"]),
                    Command("/usr/bin/hdiutil", ["detach", "/dev/disk42"])
                ]
        )
        #expect(checked.list == ["ext2 /tmp/w/ext2.img [\"/renamed/moved.bin\", \"/short.bin\"]"])
    }

    @Test func theOperationsCoverEveryChangeTheWriterSupports() {
        let names = WriteCheck.operations(point: "/p", payload: "/h")
            .map { ($0.executable as NSString).lastPathComponent }
        for name in ["cp", "cmp", "mkdir", "mv", "ln", "rm", "truncate", "chmod", "sh"] {
            #expect(names.contains(name), "\(name)")
        }
        #expect(
            WriteCheck.operations(point: "/p", payload: "/h")
                .contains(Command("/bin/ln", ["-s", "moved.bin", "/p/folder/link"]))
        )
    }

    @Test func aFailedMountChangesNothingAndStillDetaches() {
        let runner = Self.runner(failing: "/sbin/mount")
        let checked = Checked()
        let outcome = Self.check(runner, checked: checked).run(Self.target, in: Self.workspace)
        #expect(outcome.problems.count == 1 && outcome.problems[0].contains("mount"))
        #expect(runner.executables == ["/usr/bin/hdiutil", "/sbin/mount", "/usr/bin/hdiutil"])
        #expect(checked.list.isEmpty, "nothing was written to check")
    }

    @Test func aFailedOperationStopsTheRestButReleasesAndChecks() {
        let runner = Self.runner(failing: "/bin/mkdir")
        let checked = Checked()
        let outcome = Self.check(runner, checked: checked, verdict: ["e2fsck: 4"]).run(Self.target, in: Self.workspace)
        #expect(outcome.problems.first?.contains("/bin/mkdir") == true)
        #expect(outcome.problems.last == "e2fsck: 4")
        #expect(!runner.executables.contains("/bin/mv"), "nothing after the failure")
        #expect(runner.executables.suffix(2) == ["/sbin/umount", "/usr/bin/hdiutil"])
        #expect(checked.list.count == 1)
    }

    @Test func theCopyHasItsOwnIdentityAndThePayloadItsHashes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("writecheck-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/TestImages", withIntermediateDirectories: true)
        let original = Data((0 ..< 8192).map { UInt8($0 % 251) })
        try original.write(to: URL(fileURLWithPath: root + "/TestImages/ext2.img"))
        let workspace = try WriteCheck.prepare(Self.target, root: root, in: root + "/work")
        let copy = try Data(contentsOf: URL(fileURLWithPath: workspace.image))
        let identity = Self.target.identityOffset ..< (Self.target.identityOffset + 16)
        #expect(copy.count == original.count)
        #expect(copy[identity] != original[identity])
        #expect(copy[..<identity.lowerBound] == original[..<identity.lowerBound])
        #expect(copy[identity.upperBound...] == original[identity.upperBound...])
        let payload = try Data(contentsOf: URL(fileURLWithPath: workspace.payload))
        #expect(payload.count % 4096 != 0, "a partial last block")
        #expect(workspace.expected["/renamed/moved.bin"] == WriteCheck.sha256(payload))
        #expect(workspace.expected["/hard.bin"] == WriteCheck.sha256(payload))
        // Truncated to 100 bytes, then the payload appended.
        #expect(workspace.expected["/short.bin"] == WriteCheck.sha256(payload.prefix(100) + payload))
        #expect(FileManager.default.fileExists(atPath: workspace.point))
    }
}
