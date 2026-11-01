/// Runs a system command (`mount_nfs`, `umount`): the seam that keeps the backends' tests from mounting anything.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> CommandResult
}
