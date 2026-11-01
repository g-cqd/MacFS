import Darwin
import Dispatch
import FSCore
import Formats
import Foundation
import MountKit
import MountRegistry
import NFSProxy

/// `--mount` and `--sweep`: the NFS proxy through the mount seam and its registry (roadmap 0035), as the agent will run it
/// (0039). Until the agent exists, this process is the proxy's owner: the mount lives as long as it does.
enum MountMode {
    static let defaultRegistry =
        NSHomeDirectory() + "/Library/Application Support/MacFS/registry-cli.pb"

    static func service(registry: String) throws -> MountService {
        let table = SystemMountTable()
        return try MountService(
            backends: [NFSMountBackend.system(table: table)],
            store: ProtobufRegistryStore(path: registry),
            table: table,
            newID: { UUID().uuidString }
        )
    }

    /// Mounts `image` at `directory`, then waits for SIGINT or SIGTERM and unmounts.
    static func mount(_ image: String, at directory: String, registry: String) throws -> Never {
        let service = try service(registry: registry)
        let swept = service.sweep()
        if !swept.unmounted.isEmpty || !swept.forgotten.isEmpty { print("swept: \(describe(swept))") }
        let record = try service.mount(source: image, kind: .nfs, at: directory)
        print("mounted \(image) at \(record.mountPoint) from \(record.mountedFrom) (record \(record.id))")
        fflush(stdout)
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                do {
                    try service.unmount(id: record.id)
                    print("unmounted \(record.mountPoint)")
                    exit(0)
                } catch {
                    print("macfs-nfsd: \(error)")
                    exit(1)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        dispatchMain()
    }

    nonisolated(unsafe) static var signalSources: [any DispatchSourceSignal] = []

    static func sweep(registry: String) throws {
        print(describe(try service(registry: registry).sweep()))
    }

    static func describe(_ report: SweepReport) -> String {
        "kept \(report.kept.count), unmounted \(report.unmounted.count), forgotten \(report.forgotten.count), "
            + "skipped \(report.skipped.count), failed \(report.failed.count)\(report.unsaved ? ", registry not saved" : "")"
    }
}
