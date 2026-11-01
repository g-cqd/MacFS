import Foundation
public import MountKit
import Synchronization

/// The NFS proxy behind the mount seam (roadmap 0035): one `LoopbackServer` per mount, at a fresh single-use export, mounted
/// soft by `NFSMountCommand` (ADR-0014). A proxy lives in this process: after a restart no record is served, and the sweep
/// unmounts what a previous process left (the kernel also does, `deadtimeout` seconds after the proxy died).
public final class NFSMountBackend: MountBackend {
    public let kind = MountBackendKind.nfs
    private let runner: any CommandRunning
    private let table: any MountTable
    private let owner: (uid: UInt32, gid: UInt32)
    private let open: @Sendable (String) throws -> MountedTree
    private let servers = Mutex<[String: LoopbackServer]>([:])

    public init(
        runner: any CommandRunning,
        table: any MountTable,
        owner: (uid: UInt32, gid: UInt32),
        open: @escaping @Sendable (String) throws -> MountedTree
    ) {
        self.runner = runner
        self.table = table
        self.owner = owner
        self.open = open
    }

    public func availability(of source: String) -> MountAvailability {
        FileManager.default.isReadableFile(atPath: source) ? .available : .unavailable("\(source) cannot be read")
    }

    public func mount(_ request: MountRequest) throws(MountError) -> String {
        let tree: MountedTree
        do { tree = try open(request.source) } catch { throw .backend("\(request.source): \(error)") }
        let export = NFSExport.random()
        let server: LoopbackServer
        do {
            server = try LoopbackServer(dispatcher: NFSDispatcher(tree: tree, owner: owner, export: export), port: 0)
        } catch { throw .backend("the proxy did not start: \(error)") }
        try? FileManager.default.createDirectory(atPath: request.mountPoint, withIntermediateDirectories: true)
        let command = NFSMountCommand(port: server.port, export: export, mountPoint: request.mountPoint)
        let result = runner.run(command.executable, command.arguments)
        guard result.status == 0 else {
            server.stop()
            _ = unsafe rmdir(request.mountPoint)
            throw .backend("mount_nfs exited \(result.status): \(result.output)")
        }
        servers.withLock { $0[request.id] = server }
        return "127.0.0.1:\(export.path)"
    }

    /// `umount`, then `umount -f` if the mount stays; the proxy stops once the mount is gone, never before (a proxy stopped
    /// under a live mount is the wedge ADR-0014 avoids). `umount` takes a path and removes whatever is mounted there, so it runs
    /// only while the table shows this record's mount at that point: after the user ejected ours, the point may hold another
    /// mount (TLC's trace, docs/models/MountLifecycle.tla).
    public func unmount(_ record: MountRecord) throws(MountError) {
        guard isMounted(record) else {
            servers.withLock { $0.removeValue(forKey: record.id) }?.stop()
            return
        }
        var result = runner.run("/sbin/umount", [record.mountPoint])
        if isMounted(record) { result = runner.run("/sbin/umount", ["-f", record.mountPoint]) }
        guard !isMounted(record) else { throw .backend("umount -f exited \(result.status): \(result.output)") }
        servers.withLock { $0.removeValue(forKey: record.id) }?.stop()
        _ = unsafe rmdir(record.mountPoint)  // only if empty, as a mount point left by us is
    }

    public func forget(_ record: MountRecord) {
        servers.withLock { $0.removeValue(forKey: record.id) }?.stop()
        _ = unsafe rmdir(record.mountPoint)  // only if empty
    }

    public func isServing(_ record: MountRecord) -> Bool { servers.withLock { $0[record.id] != nil } }

    public func claims(_ entry: MountTableEntry) -> Bool {
        entry.type == "nfs" && entry.mountedFrom.hasPrefix("127.0.0.1:/macfs-")
    }

    private func isMounted(_ record: MountRecord) -> Bool {
        table.entries().contains { $0.mountPoint == record.mountPoint && $0.mountedFrom == record.mountedFrom }
    }
}
