/// What a command exited with, and what it printed (standard output and error together).
public struct CommandResult: Hashable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}
