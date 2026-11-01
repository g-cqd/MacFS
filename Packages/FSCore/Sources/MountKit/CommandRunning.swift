/// Runs a system command (`mount_nfs`, `umount`): the seam that keeps the backends' tests from mounting anything. Each call
/// names its deadline; past it the command is stopped and reported as such (ADR-0017).
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: Duration) -> CommandResult
}
