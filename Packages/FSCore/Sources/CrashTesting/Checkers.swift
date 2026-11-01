import Foundation

/// Each format's own checker, run in the container image `Scripts/checkers/Containerfile` builds (ADR-0018 decision 5):
/// `container build -t macfs-checkers:1 -f Scripts/checkers/Containerfile Scripts/checkers`.
public enum Checkers {
    public static let image = "macfs-checkers:1"
    static let container = "/opt/homebrew/bin/container"

    public struct Result: Sendable, Equatable {
        public let status: Int32
        public let output: String
    }

    /// Whether the container tool and the checkers' image are here; the tests that need them are skipped otherwise.
    public static var isAvailable: Bool {
        guard FileManager.default.isExecutableFile(atPath: container) else { return false }
        return run(container, ["image", "inspect", image]).status == 0
    }

    /// `command` (e2fsck -fn, xfs_repair -n, …) on each image, in one container run; nil when the run itself failed.
    public static func run(_ command: [String], on images: [String: [UInt8]]) -> [String: Result]? {
        run([command], on: images)?.compactMapValues(\.first)
    }

    /// `commands` on each image in order (a repair, then a check), in one container run: each image's results in that order.
    public static func run(_ commands: [[String]], on images: [String: [UInt8]]) -> [String: [Result]]? {
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
        let ran = run(container, ["run", "--rm", "-v", "\(directory.path):/work", image, "sh", "-c", script])
        guard ran.status == 0 else { return nil }
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

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(error)") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
