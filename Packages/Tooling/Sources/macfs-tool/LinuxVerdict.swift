import CrashTesting
import Foundation
import Synchronization
import ToolingCore

/// The format's own tools on Linux, in the checkers' container image, on a copy MacFS wrote (roadmap 0046): the checker finds
/// it consistent, and the files read back hash as written. The container system is started only when it is down, and stopped
/// when this process exits if it was started here.
enum LinuxVerdict {
    /// The problems with `image`, which should hold files of the given SHA-256 (volume path to hex).
    static func problems(_ target: WriteCheck.Target, _ image: String, _ expected: [String: String]) -> [String] {
        guard target.type == "ext4" else { return ["no Linux checker for \(target.type)"] }
        guard Checkers.isAvailable else { return ["checkers: no container tool, or no \(Checkers.image) image"] }
        guard let bytes = FileManager.default.contents(atPath: image) else { return ["checkers: cannot read \(image)"] }
        // Each file dumped by debugfs and hashed; the script holds no single quote, as Checkers quotes with them.
        let dumps =
            "for p in \(expected.keys.sorted().joined(separator: " ")); do "
            + "debugfs -R \"dump $p /tmp/o\" \"$0\" >/dev/null 2>&1 && echo \"$p $(sha256sum /tmp/o | cut -c1-64)\"; "
            + "rm -f /tmp/o; done"
        guard
            let steps = wait({
                await Checkers.run([["e2fsck", "-fn"], ["sh", "-c", dumps]], on: ["copy": Array(bytes)])
            }),
            let results = steps["copy"], results.count == 2
        else { return ["checkers: the container run failed"] }
        var problems: [String] = []
        if results[0].status != 0 {
            problems.append("e2fsck -fn: \(results[0].status) \(results[0].output.suffix(400))")
        }
        var found: [String: String] = [:]
        for line in results[1].output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2 { found[String(parts[0])] = String(parts[1]) }
        }
        for (path, hash) in expected.sorted(by: { $0.key < $1.key }) where found[path] != hash {
            problems.append("debugfs: \(path) \(found[path].map { "hashes \($0)" } ?? "is missing"), expected \(hash)")
        }
        return problems
    }

    /// An async result, waited for on this thread (the tool is synchronous).
    private static func wait<Value: Sendable>(_ body: @escaping @Sendable () async -> Value) -> Value {
        let result = Box<Value>()
        let done = DispatchSemaphore(value: 0)
        Task {
            let value = await body()
            result.value.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        guard let value = result.value.withLock({ $0 }) else { preconditionFailure("the task ended without a value") }
        return value
    }

    private final class Box<Value: Sendable>: Sendable {
        let value = Mutex<Value?>(nil)
    }
}
