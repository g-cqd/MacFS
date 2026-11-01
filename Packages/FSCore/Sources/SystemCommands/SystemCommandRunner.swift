import Dispatch
public import MountKit
import Subprocess
import System

/// Runs a command and waits for it, never longer than `timeout` plus `grace` (ADR-0017, roadmap 0048).
///
/// The command gets its own process group. Past its deadline the group gets SIGTERM, and SIGKILL `grace` later, so neither the
/// command nor anything it started outlives the call, and a grandchild holding an output pipe cannot keep the call waiting.
/// Each stream is kept to its first `limit` bytes and the rest is read and dropped, so a chatty command keeps its status. The
/// output is standard output, then standard error, trimmed. Descriptors the caller holds (an image received over XPC) are not
/// inherited.
///
/// `run` blocks the calling thread: the agent calls it on its XPC queues and `macfs-nfsd` on its own thread, never from the
/// cooperative pool, whose threads the command's own task needs (Everest: a blocked pool deadlocked its mounts).
public struct SystemCommandRunner: CommandRunning {
    /// The status of a command stopped at its deadline, as `timeout(1)` reports it.
    public static let timedOut: Int32 = 124
    /// The status of a command that could not be started, as a shell reports it.
    public static let notRun: Int32 = 127

    let timeout: Duration
    let grace: Duration
    let limit: Int

    public init(timeout: Duration = .seconds(60), grace: Duration = .seconds(2), limit: Int = 64 * 1024) {
        self.timeout = timeout
        self.grace = grace
        self.limit = limit
    }

    public func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            box.result = await runWithDeadline(executable, arguments)
            done.signal()
        }
        done.wait()
        return box.result ?? CommandResult(status: Self.notRun, output: "\(executable) produced no result")
    }

    private func runWithDeadline(_ executable: String, _ arguments: [String]) async -> CommandResult {
        let outcome = await withTaskGroup(of: CommandResult?.self) { group in
            group.addTask { await runToCompletion(executable, arguments) }
            group.addTask {
                // Cancelled when the command finishes first; then it is not a timeout.
                guard (try? await Task.sleep(for: timeout)) != nil else { return nil }
                return CommandResult(
                    status: Self.timedOut,
                    output: "\(executable) did not finish within \(timeout.components.seconds) seconds and was stopped"
                )
            }
            let first = await group.next() ?? nil
            // Cancelling the command's task runs its teardown: SIGTERM to the group, SIGKILL after `grace`.
            group.cancelAll()
            return first
        }
        return outcome ?? CommandResult(status: Self.notRun, output: "\(executable) produced no result")
    }

    private func runToCompletion(_ executable: String, _ arguments: [String]) async -> CommandResult {
        var options = PlatformOptions()
        options.processGroupID = 0
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: grace)]
        let limit = limit
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(arguments),
                platformOptions: options,
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                async let output = Self.keep(execution.standardOutput, limit: limit)
                let error = try await Self.keep(execution.standardError, limit: limit)
                return (try await output, error)
            }
            let (output, error) = result.closureResult
            let text = [output, error].map { String(decoding: $0, as: UTF8.self).trimmed }.filter { !$0.isEmpty }
            return CommandResult(status: result.terminationStatus.code, output: text.joined(separator: "\n"))
        } catch {
            if Task.isCancelled { return CommandResult(status: Self.timedOut, output: "\(executable) was stopped") }
            return CommandResult(status: Self.notRun, output: "\(executable): \(error)")
        }
    }

    /// The stream's first `limit` bytes; the rest is read and dropped, so the command never blocks on a full pipe.
    private static func keep(_ stream: SubprocessOutputSequence, limit: Int) async throws -> [UInt8] {
        var kept: [UInt8] = []
        for try await buffer in stream where kept.count < limit {
            buffer.withUnsafeBytes { kept += $0.prefix(limit - kept.count) }
        }
        return kept
    }
}

/// Written once by the command's task before it signals, read once by the waiting thread after.
private final class ResultBox: @unchecked Sendable {
    var result: CommandResult?
}

extension TerminationStatus {
    /// The exit code, or 128 plus the signal, as a shell reports a command killed by one.
    fileprivate var code: Int32 {
        switch self {
            case .exited(let code): code
            case .signaled(let signal): 128 + signal
        }
    }
}

extension String {
    fileprivate var trimmed: String {
        var scalars = Substring(self)
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        while let first = scalars.first, first.isWhitespace { scalars.removeFirst() }
        return String(scalars)
    }
}
