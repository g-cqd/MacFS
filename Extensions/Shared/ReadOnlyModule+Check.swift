import FSCore
import FSKit
import Formats

/// The check FSKit runs for `fsck_fskit` and for Disk Arbitration before it mounts a writable device (roadmap 0046): `-q`,
/// then `-y` when that fails; a failed repair refuses the mount (diary 2026-11-02-02). The verdict is ``VolumeCheck``'s, on the
/// device of this process's probe; the device is only read. Formatting is not offered.
extension ReadOnlyModule: FSManageableResourceMaintenanceOperations {
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let device else { throw POSIXError(.ENODEV) }
        let arguments = options.taskOptions
        let report = VolumeCheck.run(format, on: BlockDeviceSource(device), options: arguments)
        log.notice(
            "check \(device.bsdName, privacy: .public) \(arguments, privacy: .public): \(report.passed ? "passed" : "failed", privacy: .public), \(report.messages, privacy: .public)"
        )
        for message in report.messages { task.logMessage(message) }
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        // EILSEQ: the volume is inconsistent (fsck's "errors found"), not the device failing.
        task.didComplete(error: report.passed ? nil : POSIXError(.EILSEQ))
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw POSIXError(.ENOTSUP)
    }
}
