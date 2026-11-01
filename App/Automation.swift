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
        let argument = arguments.count > 2 ? arguments[2] : ""
        switch command {
            case "--register-agent":
                do { try ExtensionStatus.agent.register() } catch { say("register: \(error)") }
                say("agent: \(ExtensionStatus.agentState())")
                exit(ExtensionStatus.agentState() == .enabled ? 0 : 1)
            case "--mount-image", "--list-mounts", "--unmount":
                exit(agent(command, argument))
            default:
                return
        }
    }

    private static func agent(_ command: String, _ argument: String) -> Int32 {
        do throws(MountError) {
            let client = try AgentConnection.client()
            switch command {
                case "--mount-image":
                    let fd = open(argument, O_RDONLY)
                    guard fd >= 0 else {
                        say("open \(argument): errno \(errno)")
                        return 1
                    }
                    defer { close(fd) }
                    let record = try client.mount(source: argument, kind: .nfs, at: "", descriptor: fd)
                    say("mounted \(record.source) at \(record.mountPoint) (\(record.id))")
                case "--unmount":
                    try client.unmount(id: argument)
                    say("unmounted \(argument)")
                default:
                    for record in try client.list() { say("\(record.id)\t\(record.mountPoint)\t\(record.source)") }
            }
            return 0
        } catch {
            say("\(command): \(error)")
            return 1
        }
    }
}
