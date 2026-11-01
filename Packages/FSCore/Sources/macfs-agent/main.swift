import Darwin
import Dispatch
import FSCore
import Formats
import Foundation
import MountAgent
import MountKit
import MountRegistry
import NFSProxy

// macfs-agent [--service NAME] [--registry PATH]          the launch agent: owns proxy mounts (roadmap 0039)
// macfs-agent call list|sweep|mount IMAGE [DIR]|unmount ID [--service NAME]   (mount sends the opened image's descriptor)
//
// launchd starts the agent on demand through its Mach service. It sweeps the registry first, then answers MacFS's own
// binaries only (same team). `call` is a client for scripts and checks; signed by another team, it is refused.

if #available(macOS 27, *) {
    run()
} else {
    print("macfs-agent: needs macOS 27 (XPC peer requirements and descriptors)")
    exit(1)
}

@available(macOS 27, *)
func run() -> Never {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) -> String? { arguments.firstIndex(of: name).map { arguments[$0 + 1] } }
    let service = option("--service") ?? AgentListener.service

    if arguments.first == "call" {
        do throws(MountError) {
            let status = try AgentConnection.withClient(service: service) { client throws(MountError) -> Int32 in
                switch arguments.dropFirst().first {
                    case "list":
                        for record in try client.list() {
                            print(
                                "\(record.id)\t\(record.kind)\t\(record.state)\t\(record.source)\t\(record.mountPoint)\t\(record.mountedFrom)"
                            )
                        }
                    case "sweep":
                        let report = try client.sweep()
                        print(
                            "kept \(report.kept.count), unmounted \(report.unmounted.count), forgotten \(report.forgotten.count)"
                        )
                    case "mount" where arguments.count >= 3:
                        // As the app does: open the image here, send the descriptor, and let the agent read through it.
                        let fd = open(arguments[2], O_RDONLY)
                        guard fd >= 0 else {
                            print("macfs-agent: cannot open \(arguments[2]): errno \(errno)")
                            return 1
                        }
                        defer { close(fd) }
                        let point = arguments.count > 3 && !arguments[3].hasPrefix("--") ? arguments[3] : ""
                        let record = try client.mount(source: arguments[2], kind: .nfs, at: point, descriptor: fd)
                        print("mounted \(record.source) at \(record.mountPoint) (\(record.id))")
                    case "unmount" where arguments.count >= 3:
                        try client.unmount(id: arguments[2])
                        print("unmounted \(arguments[2])")
                    default:
                        print("usage: macfs-agent call list|sweep|mount IMAGE DIR|unmount ID")
                        return 64
                }
                return 0
            }
            exit(status)
        } catch {
            print("macfs-agent: \(error)")
            exit(1)
        }
    }

    let registry = option("--registry") ?? NSHomeDirectory() + "/Library/Application Support/MacFS/registry.pb"
    do {
        let table = SystemMountTable()
        let mounts = try MountService(
            backends: [NFSMountBackend.system(table: table)],
            store: ProtobufRegistryStore(path: registry),
            table: table,
            newID: { UUID().uuidString }
        )
        let swept = mounts.sweep()
        print("macfs-agent: \(registry): unmounted \(swept.unmounted.count), forgotten \(swept.forgotten.count)")
        fflush(stdout)
        signal(SIGPIPE, SIG_IGN)
        let mountsDirectory = (registry as NSString).deletingLastPathComponent + "/Mounts"
        let listener = try AgentListener(
            service: service,
            dispatcher: AgentDispatcher(service: mounts, mounts: mountsDirectory)
        )
        withExtendedLifetime(listener) { dispatchMain() }
    } catch {
        print("macfs-agent: \(error)")
        exit(1)
    }
}
