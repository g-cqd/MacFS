import Foundation

/// The automount stays read-only (ADR-0018, roadmap 0046): a writable copy attached the ordinary way, so Disk Arbitration
/// mounts it (after the module's check), must refuse a write; it is detached whatever happened. Once the modules had a check,
/// an automount was read-write until writes had to be asked for by name.
public struct AutomountCheck: Sendable {
    let runner: any ProcessRunning
    let writeRefused: @Sendable (String) -> Bool

    public init(runner: any ProcessRunning, writeRefused: @escaping @Sendable (String) -> Bool) {
        self.runner = runner
        self.writeRefused = writeRefused
    }

    public func run(image: String) -> [String] {
        guard
            let attach = try? runner.run(Command("/usr/bin/hdiutil", ["attach", image])), attach.status == 0,
            let device = MountCheck.device(attach.output)
        else { return ["automount: no device for \(image)"] }
        defer { _ = try? runner.run(Command("/usr/bin/hdiutil", ["detach", device])) }
        guard let point = Self.mountPoint(attach.output) else { return ["automount: \(device) was not mounted"] }
        return writeRefused(point) ? [] : ["automount: \(point) accepted a write"]
    }

    /// The mount point `hdiutil attach` reports: its first line's third tab-separated field.
    static func mountPoint(_ output: String) -> String? {
        output.split(separator: "\n")
            .lazy
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
            .compactMap { $0.count >= 3 ? String($0[2]).trimmingCharacters(in: .whitespaces) : nil }
            .first { !$0.isEmpty }
    }
}
