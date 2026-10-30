import Synchronization
import ToolingCore

/// A runner that executes nothing: it records each command and answers from a script.
final class RecordingRunner: ProcessRunning {
    let commands = Mutex<[Command]>([])
    private let answer: @Sendable (Command) -> ProcessResult

    init(answer: @escaping @Sendable (Command) -> ProcessResult = { _ in ProcessResult(status: 0, output: "") }) {
        self.answer = answer
    }

    func run(_ command: Command) throws -> ProcessResult {
        commands.withLock { $0.append(command) }
        return answer(command)
    }

    var executables: [String] { commands.withLock { $0.map(\.executable) } }
}
