import Foundation
import MountKit
import Synchronization
import SystemCommands

/// Each format's own checker, run in the container image `Scripts/checkers/Containerfile` builds (ADR-0018 decision 5):
/// `container build -t macfs-checkers:1 -f Scripts/checkers/Containerfile Scripts/checkers`.
public enum Checkers {
    public static let image = "macfs-checkers:1"
    static let container = "/opt/homebrew/bin/container"

    public struct Result: Sendable, Equatable {
        public let status: Int32
        public let output: String
    }

    /// Whether the container tool and the checkers' image are here; the tests that need them are skipped otherwise. The
    /// container system is started when it is not running, and stopped when this process exits, if this process started it
    /// (the owner's rule: no container system left running when nothing uses it).
    public static var isAvailable: Bool {
        guard FileManager.default.isExecutableFile(atPath: container) else { return false }
        guard
            startedHere.withLock({ (started) -> Bool in
                if status(container, ["system", "status"]) == 0 { return true }
                guard status(container, ["system", "start"]) == 0 else { return false }
                if !started {
                    started = true
                    atexit { _ = Checkers.status(Checkers.container, ["system", "stop"]) }
                }
                return true
            })
        else { return false }
        return status(container, ["image", "inspect", image]) == 0
    }

    /// Whether this process started the container system (and so stops it at exit).
    private static let startedHere = Mutex(false)

    /// `command` (e2fsck -fn, xfs_repair -n, …) on each image, in one container run; nil when the run itself failed.
    public static func run(_ command: [String], on images: [String: [UInt8]]) async -> [String: Result]? {
        await run([command], on: images)?.compactMapValues(\.first)
    }

    /// One container run at a time: the test suites run in parallel, and a host starting many containers at once failed one.
    private static let gate = Gate()

    private actor Gate {
        func run(_ arguments: [String]) async -> CommandResult {
            await withCheckedContinuation { finished in
                // SystemCommandRunner blocks its caller: from a thread of its own, never the pool (ADR-0017). A deadline
                // and process-group teardown: a `container` helper holding the output pipe once hung the suite.
                Thread.detachNewThread {
                    let runner = SystemCommandRunner(output: .last(1 << 16))
                    finished.resume(returning: runner.run(Checkers.container, arguments, timeout: .seconds(600)))
                }
            }
        }
    }

    /// `commands` on each image in order (a repair, then a check), in one container run: each image's results in that order.
    public static func run(_ commands: [[String]], on images: [String: [UInt8]]) async -> [String: [Result]]? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("checkers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, bytes) in images {
                try Data(bytes).write(to: directory.appendingPathComponent("\(name).img"))
            }
        } catch { return nil }
        let steps = commands.enumerated()
            .map { index, command in
                let quoted = command.map { "'\($0)'" }.joined(separator: " ")
                return "\(quoted) \"$f\" > \"$f.\(index).out\" 2>&1; echo $? > \"$f.\(index).status\""
            }
        let script = "for f in /work/*.img; do \(steps.joined(separator: "; ")); done"
        let arguments = ["run", "--rm", "-v", "\(directory.path):/work", image, "sh", "-c", script]
        var ran = await gate.run(arguments)
        // Under the whole suite's load a run has failed before its script started; once more, after a pause.
        if ran.status != 0 {
            print("checkers: \(ran.status), retrying: \(ran.output.replacingOccurrences(of: "\r", with: "\n"))")
            try? await Task.sleep(for: .seconds(5))
            ran = await gate.run(arguments)
        }
        guard ran.status == 0 else {
            print("checkers: \(ran.status) \(ran.output.replacingOccurrences(of: "\r", with: "\n"))")
            return nil
        }
        var results: [String: [Result]] = [:]
        for name in images.keys {
            let base = directory.appendingPathComponent("\(name).img").path
            var steps: [Result] = []
            for index in commands.indices {
                guard
                    let status = (try? String(contentsOfFile: "\(base).\(index).status", encoding: .utf8))
                        .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                    let output = try? String(contentsOfFile: "\(base).\(index).out", encoding: .utf8)
                else { return nil }
                steps.append(Result(status: status, output: output))
            }
            results[name] = steps
        }
        return results
    }

    /// A short command's status, its output not read (nothing can hold a pipe that does not exist).
    static func status(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return 127 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
