import Foundation
import MountKit
import NFSProxy
import Synchronization
import Testing

/// Commands as a fake system runs them: `mount_nfs` succeeds unless told otherwise and adds a table entry, `umount` removes it
/// unless the mount is busy (then only `-f` does).
final class FakeSystem: CommandRunning, MountTable {
    let commands = Mutex<[[String]]>([])
    let mounted = Mutex<[MountTableEntry]>([])
    let mountStatus = Mutex<Int32>(0)
    let busy = Mutex(false)

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        commands.withLock { $0.append([executable] + arguments) }
        switch executable {
            case "/sbin/mount_nfs":
                let status = mountStatus.withLock { $0 }
                if status == 0 {
                    let from = arguments[arguments.count - 2]
                    mounted.withLock {
                        $0.append(MountTableEntry(mountPoint: arguments.last!, mountedFrom: from, type: "nfs"))
                    }
                }
                return CommandResult(status: status, output: status == 0 ? "" : "mount_nfs: can't mount")
            case "/sbin/umount":
                let force = arguments.first == "-f"
                if busy.withLock({ $0 }), !force { return CommandResult(status: 16, output: "Resource busy") }
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
            try MountedTree(InMemoryFileSystem(root: 5, files: 3))
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
        #expect(
            backend.availability(of: "/nonexistent/disk.img") == .unavailable("/nonexistent/disk.img cannot be read")
        )
        #expect(backend.availability(of: "/etc/hosts") == .available)
    }
}
