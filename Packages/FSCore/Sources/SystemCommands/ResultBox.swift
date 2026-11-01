import MountKit
import Synchronization

/// Written by the command's task, perhaps after the caller stopped waiting; read by the caller after the task signalled.
final class ResultBox: Sendable {
    private let result = Mutex(CommandResult(status: SystemCommandRunner.notRun, output: "no result"))

    func set(_ value: CommandResult) { result.withLock { $0 = value } }
    var value: CommandResult { result.withLock { $0 } }
}
