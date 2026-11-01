import Dispatch
public import MountKit
import Subprocess
import System

/// Runs a command and waits for it, never longer than its deadline plus `grace` plus a second (ADR-0017, roadmap 0048).
///
/// The command gets its own process group. Past its deadline the group gets SIGTERM, and SIGKILL `grace` later, so neither the
/// command nor anything it started outlives the call, and a grandchild holding an output pipe cannot keep the call waiting.
/// Each stream is kept to its first `limit` bytes and the rest is read and dropped, so a chatty command keeps its status. The
/// output is standard output, then standard error, trimmed. Descriptors the caller holds (an image received over XPC) are not
/// inherited.
///
/// `run` blocks the calling thread: the agent calls it on its XPC queues and `macfs-nfsd` on its own thread, never from the
/// cooperative pool, whose threads the command's own task needs (Everest: a blocked pool deadlocked its mounts). Called from
/// a task, it refuses rather than risk that.
public struct SystemCommandRunner: CommandRunning {
    /// The status of a command stopped at its deadline, as `timeout(1)` reports it.
    public static let timedOut: Int32 = 124
    /// The status of a command that could not be started, as a shell reports it.
    public static let notRun: Int32 = 127

    let grace: Duration
    /// The command's work: the process, or in the tests one that does not end.
    let command: @Sendable (String, [String]) async -> CommandResult

    /// What the runner keeps of a command's output.
    public enum Output: Sendable, Equatable {
        /// Standard output, then standard error, each to its first so many bytes: a command's message comes first (the agent).
        case first(Int)
        /// Both streams merged as they were written, to their last so many bytes: a build's error comes last (the tooling).
        case last(Int)
        /// Our own streams, given to the command: nothing kept (the gates, as they run).
        case passedThrough
    }

    public init(grace: Duration = .seconds(2), output: Output = .first(64 * 1024)) {
        self.grace = grace
        self.command = { executable, arguments in
            await Self.runToCompletion(executable, arguments, grace: grace, output: output)
        }
    }

    /// For the tests: `command` in place of the process, to model one that does not end.
    init(grace: Duration, command: @escaping @Sendable (String, [String]) async -> CommandResult) {
        self.grace = grace
        self.command = command
    }

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) -> CommandResult {
        // Called from a task, the wait below would hold one of the pool's threads, which the command's own task needs: with
        // enough such calls at once none is left, and commands that finished would be reported as timed out.
        if withUnsafeCurrentTask(body: { $0 != nil }) {
            return CommandResult(
                status: Self.notRun,
                output: "\(executable) was not run: called from a task, whose thread the wait would block (ADR-0017)"
            )
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = Task.detached { [command] in
            box.set(await command(executable, arguments))
            done.signal()
        }
        if done.wait(timeout: .now() + timeout.dispatch) == .success { return box.value }
        // Cancelling the command's task runs its teardown: SIGTERM to the group, SIGKILL after `grace`.
        task.cancel()
        let late = "\(executable) did not finish within \(timeout.components.seconds) seconds"
        if done.wait(timeout: .now() + (grace + .seconds(1)).dispatch) == .success {
            return CommandResult(status: Self.timedOut, output: late + " and was stopped")
        }
        // Not ended by SIGKILL: stuck in the kernel (a `umount` on a frozen NFS server). The task reaps it when it ends.
        return CommandResult(status: Self.timedOut, output: late + ", nor end after SIGKILL; it is reaped when it does")
    }

    private static func runToCompletion(
        _ executable: String,
        _ arguments: [String],
        grace: Duration,
        output policy: Output
    ) async -> CommandResult {
        var options = PlatformOptions()
        options.processGroupID = 0
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: grace)]
        let configuration = Configuration(
            executable: .path(FilePath(executable)),
            arguments: Arguments(arguments),
            platformOptions: options
        )
        do {
            switch policy {
                case .first(let limit):
                    let result = try await Subprocess.run(
                        configuration,
                        input: .none,
                        output: .sequence,
                        error: .sequence
                    ) { execution in
                        async let output = Self.first(limit, of: execution.standardOutput)
                        let error = try await Self.first(limit, of: execution.standardError)
                        return (try await output, error)
                    }
                    let (output, error) = result.closureResult
                    return CommandResult(status: result.terminationStatus.code, output: text(output, error))
                case .last(let limit):
                    let result = try await Subprocess.run(
                        configuration,
                        input: .none,
                        output: .sequence,
                        error: .combinedWithOutput
                    ) {
                        try await Self.last(limit, of: $0.standardOutput)
                    }
                    return CommandResult(status: result.terminationStatus.code, output: text(result.closureResult))
                case .passedThrough:
                    let result = try await Subprocess.run(
                        configuration,
                        output: .currentStandardOutput,
                        error: .currentStandardError
                    )
                    return CommandResult(status: result.terminationStatus.code, output: "")
            }
        } catch {
            return CommandResult(status: Self.notRun, output: "\(executable): \(error)")
        }
    }

    /// The streams' bytes as text, each trimmed, the empty ones left out.
    private static func text(_ streams: [UInt8]...) -> String {
        streams.map { String(decoding: $0, as: UTF8.self).trimmed }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The stream's last `limit` bytes, all of it read.
    private static func last(_ limit: Int, of stream: SubprocessOutputSequence) async throws -> [UInt8] {
        var tail = Tail(limit: limit)
        for try await buffer in stream { buffer.withUnsafeBytes { tail.append($0) } }
        return tail.bytes
    }

    /// The stream's first `limit` bytes; the rest is read and dropped, so the command never blocks on a full pipe.
    private static func first(_ limit: Int, of stream: SubprocessOutputSequence) async throws -> [UInt8] {
        var kept: [UInt8] = []
        for try await buffer in stream where kept.count < limit {
            buffer.withUnsafeBytes { kept += $0.prefix(limit - kept.count) }
        }
        return kept
    }
}

extension Duration {
    var dispatch: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
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
