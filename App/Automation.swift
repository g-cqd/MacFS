import AppSupport
import Darwin
import Dispatch
import Foundation
import MountAgent
import MountKit
import OSLog

/// Scripted commands, run instead of the window when the app is launched with them, for the install and mount checks
/// (roadmap 0039, 0041). They go through the same calls as the window: the app's own `SMAppService`, and a descriptor the
/// sandboxed app opened, sent to the agent.
///
///     MacFS.app/Contents/MacOS/MacFS --register-agent      registers the agent, prints its status
///     MacFS.app/Contents/MacOS/MacFS --mount-image PATH     mounts PATH through the agent, prints the record
///     MacFS.app/Contents/MacOS/MacFS --list-mounts | --unmount ID
///
/// `--result PATH` after any of them writes what it came to as one `AutomationResult` line, for the mount check: `open` loses
/// the app's standard output. PATH must be in the app's container.
@MainActor
enum Automation {
    private static let log = Logger(subsystem: "dev.gcqd.MacFS", category: "automation")

    /// Prints and logs (`open` discards standard output: `log show --predicate 'category == "automation"'`).
    private static func say(_ line: String) {
        print(line)
        log.notice("\(line, privacy: .public)")
    }

    /// Runs the command in the arguments, if there is one, and exits; returns when there is none.
    static func runIfAsked(_ arguments: [String]) {
        guard let command = arguments.dropFirst().first, command.hasPrefix("--") else { return }
        let argument = arguments.count > 2 && !arguments[2].hasPrefix("--") ? arguments[2] : ""
        let resultPath = arguments.firstIndex(of: "--result")
            .flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let result: AutomationResult
        switch command {
            case "--register-agent":
                do { try ExtensionStatus.agent.register() } catch { say("register: \(error)") }
                let state = ExtensionStatus.agentState()
                say("agent: \(state)")
                result = state == .enabled ? .done : .failed("agent: \(state)")
            case "--mount-image", "--list-mounts", "--unmount":
                result = agent(command, argument)
            default:
                return
        }
        if let resultPath {
            do {
                try Data((result.line + "\n").utf8).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
            } catch {
                say("--result \(resultPath): \(error)")
            }
        }
        if case .failed = result { exit(1) }
        exit(0)
    }

    private static func agent(_ command: String, _ argument: String) -> AutomationResult {
        do throws(MountError) {
            return try AgentConnection.withClient { client throws(MountError) -> AutomationResult in
                switch command {
                    case "--mount-image":
                        let fd = open(argument, O_RDONLY)
                        guard fd >= 0 else {
                            let problem = "open \(argument): errno \(errno)"
                            say(problem)
                            return .failed(problem)
                        }
                        defer { close(fd) }
                        let record = try client.mount(source: argument, kind: .nfs, at: "", descriptor: fd)
                        say("mounted \(record.source) at \(record.mountPoint) (\(record.id))")
                        return .mounted(id: record.id, mountPoint: record.mountPoint)
                    case "--unmount":
                        try client.unmount(id: argument)
                        say("unmounted \(argument)")
                    default:
                        for record in try client.list() { say("\(record.id)\t\(record.mountPoint)\t\(record.source)") }
                }
                return .done
            }
        } catch {
            say("\(command): \(error)")
            return .failed("\(error)")
        }
    }
}
