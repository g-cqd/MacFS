import Foundation
import MountKit
import NFSProxy
import Synchronization
import Testing

/// Commands as a fake system runs them: `mount_nfs` succeeds unless told otherwise and adds a table entry, `umount` removes it
/// unless the mount is busy (then only `-f` does) or hung (then it is stopped at its deadline, and only `-f` does). A
/// `mount_nfs` stopped at its deadline may have mounted anyway, as the kernel can finish the call after the process dies.
final class FakeSystem: CommandRunning, MountTable {
    let commands = Mutex<[[String]]>([])
    let deadlines = Mutex<[Duration]>([])
    let hung = Mutex(false)
    let mountsAfterDeadline = Mutex(false)
    let mounted = Mutex<[MountTableEntry]>([])
    let mountStatus = Mutex<Int32>(0)
    let busy = Mutex(false)

    func run(_ executable: String, _ arguments: [String], timeout: Duration) -> CommandResult {
        commands.withLock { $0.append([executable] + arguments) }
        deadlines.withLock { $0.append(timeout) }
        switch executable {
            case "/sbin/mount_nfs":
                let status = mountStatus.withLock { $0 }
                if status == 0 || mountsAfterDeadline.withLock({ $0 }) {
                    let from = arguments[arguments.count - 2]
                    mounted.withLock {
                        $0.append(MountTableEntry(mountPoint: arguments.last!, mountedFrom: from, type: "nfs"))
                    }
                }
                return CommandResult(status: status, output: status == 0 ? "" : "mount_nfs: can't mount")
            case "/sbin/umount":
                let force = arguments.first == "-f"
                if busy.withLock({ $0 }), !force { return CommandResult(status: 16, output: "Resource busy") }
                if hung.withLock({ $0 }), !force { return CommandResult(status: 124, output: "umount was stopped") }
                mounted.withLock { table in table.removeAll { $0.mountPoint == arguments.last! } }
                return CommandResult(status: 0, output: "")
            default:
                return CommandResult(status: 127, output: "not faked")
        }
    }

    func entries() -> [MountTableEntry] { mounted.withLock { $0 } }
    func canonical(_ path: String) -> String { path }
    var ran: [[String]] { commands.withLock { $0 } }
}

/// The NFS proxy behind the mount seam (roadmap 0035): one proxy per mount, mounted with `NFSMountCommand`, stopped when its
/// mount goes or fails to come up.
@Suite struct NFSMountBackendTests {
    let system = FakeSystem()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nfsbackend-\(UUID().uuidString)")
        .path
    var backend: NFSMountBackend {
        NFSMountBackend(runner: system, table: system, owner: (501, 20)) { _ in
            OpenedVolume(try MountedTree(InMemoryFileSystem(root: 5, files: 3)))
        }
    }

    func request(_ id: String = "r1") -> MountRequest {
        MountRequest(id: id, source: "/i/a.img", mountPoint: directory + "/" + id)
    }

    @Test func aMountServesTheVolumeAndRunsTheSoftMountCommand() throws {
        let backend = backend
        let from = try backend.mount(request())
        let command = try #require(system.ran.first)
        #expect(command.first == "/sbin/mount_nfs" && command.last == directory + "/r1")
        #expect(command[command.count - 2] == from && from.hasPrefix("127.0.0.1:/macfs-"))
        let options = command[2].split(separator: ",").map(String.init)
        #expect(options.contains("soft") && options.contains("deadtimeout=\(NFSMountCommand.deadTimeout)"))
        let port = try #require(options.first { $0.hasPrefix("port=") }.flatMap { UInt16($0.dropFirst(5)) })
        #expect(LoopbackClient.connect(port: port) != nil, "its proxy listens")
        #expect(FileManager.default.fileExists(atPath: directory + "/r1"), "the mount point is made")
        let record = MountRecord(
            id: "r1",
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: directory + "/r1",
            mountedFrom: from,
            state: .mounted
        )
        #expect(backend.isServing(record))
        try backend.unmount(record)
        #expect(!backend.isServing(record))
        #expect(LoopbackClient.connect(port: port) == nil, "its proxy stopped")
        #expect(!FileManager.default.fileExists(atPath: directory + "/r1"), "the empty mount point is removed")
    }

    @Test func aMountThatDoesNotComeUpStopsItsProxy() throws {
        system.mountStatus.withLock { $0 = 13 }
        let backend = backend
        #expect(throws: MountError.backend("mount_nfs exited 13: mount_nfs: can't mount")) {
            try backend.mount(request())
        }
        let options = try #require(system.ran.first)[2].split(separator: ",")
        let port = try #require(options.first { $0.hasPrefix("port=") }.flatMap { UInt16($0.dropFirst(5)) })
        #expect(LoopbackClient.connect(port: port) == nil)
    }

    @Test func aVolumeThatDoesNotOpenIsNotMounted() {
        struct Unreadable: Error {}
        let backend = NFSMountBackend(runner: system, table: system, owner: (501, 20)) { _ in throw Unreadable() }
        #expect(throws: MountError.self) { try backend.mount(request()) }
        #expect(system.ran.isEmpty)
    }

    /// TLC's trace (docs/models/MountLifecycle.tla): ours is ejected by the user, another mount takes its point, and then ours is
    /// unmounted. `umount <point>` would unmount the other one: nothing is run, and the proxy stops.
    @Test func aMountThatIsNoLongerOursIsNotUnmounted() throws {
        let backend = backend
        let from = try backend.mount(request())
        let record = MountRecord(
            id: "r1",
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: directory + "/r1",
            mountedFrom: from,
            state: .mounted
        )
        system.mounted.withLock {
            $0 = [MountTableEntry(mountPoint: directory + "/r1", mountedFrom: "/dev/disk7s1", type: "msdos")]
        }
        let before = system.ran.count
        try backend.unmount(record)
        #expect(system.ran.count == before, "no umount of a point another mount holds")
        #expect(system.entries().map(\.mountedFrom) == ["/dev/disk7s1"])
        #expect(!backend.isServing(record), "its proxy stopped all the same")
    }

    /// A busy mount is forced: `umount`, then `umount -f`. One that stays is an error and keeps its proxy.
    @Test func aBusyMountIsForced() throws {
        let backend = backend
        let from = try backend.mount(request())
        system.busy.withLock { $0 = true }
        let record = MountRecord(
            id: "r1",
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: directory + "/r1",
            mountedFrom: from,
            state: .mounted
        )
        try backend.unmount(record)
        #expect(
            system.ran.suffix(2).map { Array($0.prefix(2)) } == [
                ["/sbin/umount", directory + "/r1"], ["/sbin/umount", "-f"]
            ]
        )
        #expect(system.entries().isEmpty)
    }

    /// Every command has a deadline: `mount_nfs` the longer one, each `umount` a shorter one, so a dead server's mount costs an
    /// unmount at most two of them (roadmap 0048).
    @Test func everyCommandHasItsDeadline() throws {
        let backend = backend
        let from = try backend.mount(request())
        system.hung.withLock { $0 = true }
        try backend.unmount(record(from))
        #expect(system.ran.map { $0.first! } == ["/sbin/mount_nfs", "/sbin/umount", "/sbin/umount"])
        #expect(
            system.deadlines.withLock { $0 }
                == [NFSMountBackend.mountDeadline, NFSMountBackend.unmountDeadline, NFSMountBackend.unmountDeadline]
        )
        #expect(NFSMountBackend.unmountDeadline < NFSMountBackend.mountDeadline)
        #expect(system.entries().isEmpty)
    }

    /// A `mount_nfs` stopped at its deadline whose mount came up anyway is forced off before its proxy stops: a proxy stopped
    /// under a live mount is the wedge ADR-0014 avoids.
    @Test func aMountStoppedAtItsDeadlineButMountedAnywayIsTakenDownBeforeItsProxy() {
        system.mountStatus.withLock { $0 = 124 }
        system.mountsAfterDeadline.withLock { $0 = true }
        #expect(throws: MountError.self) { try backend.mount(request()) }
        #expect(system.ran.map { Array($0.prefix(2)) } == [["/sbin/mount_nfs", "-o"], ["/sbin/umount", "-f"]])
        #expect(system.entries().isEmpty)
    }

    /// A mount that did not come up leaves alone what else is mounted at its point: `umount` takes a path, and would remove it.
    @Test func aFailedMountDoesNotUnmountSomethingElseAtItsPoint() {
        let other = MountTableEntry(mountPoint: directory + "/r1", mountedFrom: "/dev/disk9s1", type: "apfs")
        system.mounted.withLock { $0 = [other] }
        system.mountStatus.withLock { $0 = 32 }
        #expect(throws: MountError.self) { try backend.mount(request()) }
        #expect(system.ran.map { $0.first! } == ["/sbin/mount_nfs"])
        #expect(system.entries() == [other])
    }

    func record(_ from: String, _ id: String = "r1") -> MountRecord {
        MountRecord(
            id: id,
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: directory + "/" + id,
            mountedFrom: from,
            state: .mounted
        )
    }

    /// A record whose proxy this process does not have (a previous process's) is not served: the sweep unmounts it.
    @Test func itServesOnlyItsOwnProxiesAndClaimsOnlyItsExports() {
        let backend = backend
        let record = MountRecord(
            id: "old",
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: "/m",
            mountedFrom: "127.0.0.1:/macfs-00",
            state: .mounted
        )
        #expect(!backend.isServing(record))
        #expect(backend.claims(MountTableEntry(mountPoint: "/m", mountedFrom: "127.0.0.1:/macfs-0011", type: "nfs")))
        #expect(!backend.claims(MountTableEntry(mountPoint: "/m", mountedFrom: "nas:/export", type: "nfs")))
        #expect(!backend.claims(MountTableEntry(mountPoint: "/m", mountedFrom: "127.0.0.1:/macfs-0011", type: "smbfs")))
        #expect(backend.kind == .nfs)
    }

    /// A mount the kernel removed (its proxy died) leaves the directory the backend made: forgetting it removes it if empty.
    @Test func forgettingAMountRemovesItsEmptyMountPoint() throws {
        let point = directory + "/gone"
        try FileManager.default.createDirectory(atPath: point, withIntermediateDirectories: true)
        let record = MountRecord(
            id: "g",
            kind: .nfs,
            source: "/i/a.img",
            mountPoint: point,
            mountedFrom: "x",
            state: .mounted
        )
        backend.forget(record)
        #expect(!FileManager.default.fileExists(atPath: point))
        try FileManager.default.createDirectory(atPath: point, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: point + "/kept", contents: Data())
        backend.forget(record)
        #expect(
            FileManager.default.fileExists(atPath: point + "/kept"),
            "a directory with something in it is not ours to remove"
        )
    }

    @Test func anUnreadableSourceIsUnavailable() {
        func request(_ source: String, _ descriptor: Int32? = nil) -> MountRequest {
            MountRequest(id: "x", source: source, mountPoint: "/m", descriptor: descriptor)
        }
        #expect(
            backend.availability(of: request("/nonexistent/disk.img"))
                == .unavailable("/nonexistent/disk.img cannot be read")
        )
        #expect(backend.availability(of: request("/etc/hosts")) == .available)
        #expect(
            backend.availability(of: request("/nonexistent/disk.img", 0)) == .available,
            "a descriptor needs no path"
        )
    }

    /// The volume is read through the descriptor it was handed, not its path (which the agent may not be allowed to open),
    /// and the descriptor is closed when the mount goes, or when it fails to come up.
    @Test func theHandedDescriptorIsTheSourceAndIsClosedWithTheMount() throws {
        let opened = Mutex<[Int32?]>([])
        let backend = NFSMountBackend(runner: system, table: system, owner: (501, 20)) { request in
            opened.withLock { $0.append(request.descriptor) }
            return OpenedVolume(try MountedTree(InMemoryFileSystem(root: 5, files: 3)))
        }
        let probe = DescriptorProbe()
        let request = MountRequest(
            id: "d",
            source: "/not/readable.img",
            mountPoint: directory + "/d",
            descriptor: probe.descriptor
        )
        let from = try backend.mount(request)
        #expect(opened.withLock { $0 } == [probe.descriptor])
        #expect(!probe.isClosed, "open while mounted")
        try backend.unmount(
            MountRecord(
                id: "d",
                kind: .nfs,
                source: request.source,
                mountPoint: request.mountPoint,
                mountedFrom: from,
                state: .mounted
            )
        )
        #expect(probe.isClosed, "closed with the mount")
        system.mountStatus.withLock { $0 = 13 }
        let failing = DescriptorProbe()
        #expect(throws: MountError.self) {
            try backend.mount(
                MountRequest(id: "e", source: "/x.img", mountPoint: directory + "/e", descriptor: failing.descriptor)
            )
        }
        #expect(failing.isClosed, "closed when the mount failed")
    }
}
