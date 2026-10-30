import Formats

/// The status pane's checks from the system's facts: where the app is, whether FSKit answered, each format's module, and what
/// the system itself does with those formats. Pure, so every line the pane can show is tested.
public enum StatusEvaluation {
    public struct Summary: Sendable, Equatable {
        public let state: StatusCheck.State
        public let headline: String

        public init(state: StatusCheck.State, headline: String) {
            self.state = state
            self.headline = headline
        }
    }

    /// FSKit registers the modules of an app in /Applications only (Everest's finding, reproduced in roadmap 0006).
    static func isInApplications(_ path: String) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/")
    }

    public static func checks(_ facts: SystemFacts) -> [StatusCheck] {
        var checks: [StatusCheck] = []
        let installed = isInApplications(facts.appPath)
        checks.append(
            installed
                ? StatusCheck(id: "app.location", title: "Installed in Applications", state: .ok, detail: facts.appPath)
                : StatusCheck(
                    id: "app.location", title: "Not in Applications", state: .attention,
                    detail:
                        "macOS registers file system modules only for an app in /Applications. Running from \(facts.appPath).",
                    remedy: .moveToApplications))
        if let failure = facts.queryFailure {
            checks.append(
                StatusCheck(
                    id: "fskit.query", title: "FSKit did not answer", state: .failed,
                    detail: "The list of file system modules could not be read: \(failure)"))
        }
        for format in DiskFormat.allCases {
            checks.append(module(format, facts: facts, installed: installed))
        }
        checks.append(
            StatusCheck(
                id: "note.ntfs", title: "NTFS and macOS", state: .information,
                detail:
                    "macOS's own read-only NTFS driver mounts NTFS volumes before any module. To use MacFS for one, mount it with "
                    + "mount -F -t \(DiskFormat.ntfs.shortName), or use the in-app browser."))
        return checks
    }

    private static func module(_ format: DiskFormat, facts: SystemFacts, installed: Bool) -> StatusCheck {
        let id = "module.\(format.rawValue)"
        let title = "\(format.displayName) module"
        guard facts.queryFailure == nil else {
            return StatusCheck(id: id, title: title, state: .unknown, detail: "Unknown until FSKit answers.")
        }
        switch facts.modules[format.moduleBundleIdentifier] {
            case true:
                return StatusCheck(
                    id: id, title: title, state: .ok,
                    detail: "Enabled. Volumes mount automatically, read-only (mount -t \(format.shortName)).")
            case false:
                return StatusCheck(
                    id: id, title: title, state: .attention,
                    detail:
                        "Installed but not enabled: turn it on in System Settings → General → Login Items & Extensions.",
                    remedy: .openExtensionSettings)
            case nil:
                return StatusCheck(
                    id: id, title: title, state: .failed,
                    detail: installed
                        ? "Not registered with FSKit. Reinstall MacFS to register its modules."
                        : "Not registered: the app is not in /Applications.",
                    remedy: installed ? .reinstall : .moveToApplications)
        }
    }

    public static func summary(_ checks: [StatusCheck]) -> Summary {
        let worst = checks.map(\.state).max() ?? .ok
        let needing = checks.filter { $0.state >= .attention }.count
        switch worst {
            case .ok, .information:
                return Summary(state: .ok, headline: "Ready: every module is enabled.")
            case .unknown:
                return Summary(state: .unknown, headline: "Status unknown.")
            case .attention, .failed:
                return Summary(
                    state: worst,
                    headline: needing == 1 ? "1 item needs attention." : "\(needing) items need attention.")
        }
    }

    /// The checks as text, for "Copy Diagnostics".
    public static func report(_ checks: [StatusCheck], facts: SystemFacts) -> String {
        var lines = ["MacFS status", "app: \(facts.appPath)"]
        for check in checks { lines.append("[\(check.state)] \(check.title): \(check.detail)") }
        lines.append("modules reported by FSKit:")
        for (identifier, enabled) in facts.modules.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(identifier): \(enabled ? "enabled" : "disabled")")
        }
        for format in DiskFormat.allCases where facts.modules[format.moduleBundleIdentifier] == nil {
            lines.append("  \(format.moduleBundleIdentifier): not reported")
        }
        return lines.joined(separator: "\n")
    }
}
