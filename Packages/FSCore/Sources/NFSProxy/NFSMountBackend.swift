import Darwin
import FSCore
import Foundation
public import MountKit
import Synchronization

/// The NFS proxy behind the mount seam (roadmap 0035): one `LoopbackServer` per mount, at a fresh single-use export, mounted
/// soft by `NFSMountCommand` (ADR-0014). A proxy lives in this process: after a restart no record is served, and the sweep
/// unmounts what a previous process left (the kernel also does, `deadtimeout` seconds after the proxy died).
public final class NFSMountBackend: MountBackend {
    public let kind = MountBackendKind.nfs
    /// `mount_nfs` to a proxy in this process: it answers at once, so a mount that takes this long will not come up.
    public static let mountDeadline: Duration = .seconds(30)
    /// Each `umount`: a hung one is stopped and forced, so a dead server's mount takes at most two of these.
    public static let unmountDeadline: Duration = .seconds(10)
    private let runner: any CommandRunning
    private let table: any MountTable
    private let owner: (uid: UInt32, gid: UInt32)
    private let open: @Sendable (MountRequest) throws -> OpenedVolume
    private let servers = Mutex<[String: LoopbackServer]>([:])
    /// Descriptors handed with a request, closed once their mount is gone.
    private let descriptors = Mutex<[String: Int32]>([:])
    /// Writers of writable mounts, closed (the volume clean again) once their proxy stopped.
    private let writers = Mutex<[String: any WritableFileSystem]>([:])

    public init(
        runner: any CommandRunning,
        table: any MountTable,
        owner: (uid: UInt32, gid: UInt32),
        open: @escaping @Sendable (MountRequest) throws -> OpenedVolume
    ) {
        self.runner = runner
        self.table = table
        self.owner = owner
        self.open = open
    }

    public func availability(of request: MountRequest) -> MountAvailability {
        if request.descriptor != nil { return .available }  // read through what the app opened, not the path
        return FileManager.default.isReadableFile(atPath: request.source)
            ? .available : .unavailable("\(request.source) cannot be read")
    }

    public func mount(_ request: MountRequest) throws(MountError) -> String {
        // The descriptor is ours from here: kept while the mount lives, closed on every way out.
        func fail(_ error: MountError) -> MountError {
            if let descriptor = request.descriptor { close(descriptor) }
            return error
        }
        let opened: OpenedVolume
        do { opened = try open(request) } catch { throw fail(.backend("\(request.source): \(error)")) }
        // Writable only when asked and the writer began; a writer is closed on every way out but a live mount.
        let writer = request.writable ? opened.writer : nil
        if writer == nil { try? opened.writer?.close() }
        let export = NFSExport.random()
        let server: LoopbackServer
        do {
            let dispatcher = NFSDispatcher(tree: opened.tree, owner: owner, export: export, writer: writer)
            server = try LoopbackServer(dispatcher: dispatcher, port: 0)
        } catch {
            try? writer?.close()
            throw fail(.backend("the proxy did not start: \(error)"))
        }
        try? FileManager.default.createDirectory(atPath: request.mountPoint, withIntermediateDirectories: true)
        let command = NFSMountCommand(
            port: server.port,
            export: export,
            mountPoint: request.mountPoint,
            writable: writer != nil
        )
        let result = runner.run(command.executable, command.arguments, timeout: Self.mountDeadline)
        let from = "127.0.0.1:\(export.path)"
        guard result.status == 0 else {
            // A `mount_nfs` stopped at its deadline may have mounted anyway (the kernel can finish the call after the process
            // dies): forced off first, as the proxy must not stop under a live mount (ADR-0014).
            if table.entries().contains(where: { $0.mountPoint == request.mountPoint && $0.mountedFrom == from }) {
                _ = runner.run("/sbin/umount", ["-f", request.mountPoint], timeout: Self.unmountDeadline)
            }
            server.stop()
            try? writer?.close()
            _ = unsafe rmdir(request.mountPoint)
            throw fail(.backend("mount_nfs exited \(result.status): \(result.output)"))
        }
        servers.withLock { $0[request.id] = server }
        if let writer { writers.withLock { $0[request.id] = writer } }
        if let descriptor = request.descriptor { descriptors.withLock { $0[request.id] = descriptor } }
        return from
    }

    /// `umount`, then `umount -f` if the mount stays; the proxy stops once the mount is gone, never before (a proxy stopped
    /// under a live mount is the wedge ADR-0014 avoids). `umount` takes a path and removes whatever is mounted there, so it runs
    /// only while the table shows this record's mount at that point: after the user ejected ours, the point may hold another
    /// mount (TLC's trace, docs/models/MountLifecycle.tla).
    public func unmount(_ record: MountRecord) throws(MountError) {
        guard isMounted(record) else {
            release(record)
            return
        }
        var result = runner.run("/sbin/umount", [record.mountPoint], timeout: Self.unmountDeadline)
        if isMounted(record) {
            result = runner.run("/sbin/umount", ["-f", record.mountPoint], timeout: Self.unmountDeadline)
        }
        guard !isMounted(record) else { throw .backend("umount -f exited \(result.status): \(result.output)") }
        release(record)
        _ = unsafe rmdir(record.mountPoint)  // only if empty, as a mount point left by us is
    }

    /// Stops the record's proxy, then closes its writer (the volume clean again) and the descriptor it read through (never
    /// before: the proxy may be mid-read or mid-write).
    private func release(_ record: MountRecord) {
        servers.withLock { $0.removeValue(forKey: record.id) }?.stop()
        try? writers.withLock { $0.removeValue(forKey: record.id) }?.close()
        if let descriptor = descriptors.withLock({ $0.removeValue(forKey: record.id) }) { close(descriptor) }
    }

    public func forget(_ record: MountRecord) {
        release(record)
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
