import Foundation
import MountAgent
import MountKit
import Synchronization
import Testing

/// The XPC shells end to end in one process: an anonymous listener over a dispatcher with fake backends, and a client session to
/// its endpoint. Each case runs in a child process, so a trap in libxpc fails one test instead of ending the run; a child reports
/// a failed call by its exit status (3) and does not trap.
@Suite struct AgentConnectionTests {
    /// XPC traps (`_xpc_api_misuse`) when an active session is released without being cancelled: this crashed the app at launch
    /// once its agent was enabled (diary 2026-11-01-05). A mount and a listing, then the client goes.
    @Test func aClientUsedThenDroppedLeavesTheProcessAlive() async {
        await #expect(processExitsWith: .success) {
            if #available(macOS 27, *) {
                let log = MountLog()
                let table = FakeMountTable()
                let service = try! MountService(
                    backends: [FakeBackend(.nfs, log, table)],
                    store: MemoryStore(log),
                    table: table,
                    newID: { "rec" }
                )
                let listener = AgentListener(dispatcher: AgentDispatcher(service: service, mounts: "/Mounts"))
                do throws(MountError) {
                    let records = try AgentConnection.withClient(endpoint: listener.endpoint) {
                        client throws(MountError) in
                        _ = try client.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
                        return try client.list()
                    }
                    guard records.map(\.id) == ["rec"] else { exit(4) }
                } catch {
                    exit(3)
                }
                withExtendedLifetime(listener) {}
            }
        }
    }

    /// A reply that encodes to no bytes (an empty listing) is still a reply.
    @Test func anEmptyListingComesBackEmpty() async {
        await #expect(processExitsWith: .success) {
            if #available(macOS 27, *) {
                let log = MountLog()
                let table = FakeMountTable()
                let service = try! MountService(
                    backends: [FakeBackend(.nfs, log, table)],
                    store: MemoryStore(log),
                    table: table,
                    newID: { "rec" }
                )
                let listener = AgentListener(dispatcher: AgentDispatcher(service: service, mounts: "/Mounts"))
                do throws(MountError) {
                    let records = try AgentConnection.withClient(endpoint: listener.endpoint) {
                        client throws(MountError) in try client.list()
                    }
                    guard records.isEmpty else { exit(4) }
                } catch {
                    exit(3)
                }
                withExtendedLifetime(listener) {}
            }
        }
    }

    /// The opened image crosses XPC: the backend is handed a descriptor of the same open file (XPC duplicates it), and the
    /// caller's own stays open for the caller to close.
    @Test func aMountCarriesTheImageDescriptorAcross() async {
        await #expect(processExitsWith: .success) {
            if #available(macOS 27, *) {
                let log = MountLog()
                let table = FakeMountTable()
                let nfs = FakeBackend(.nfs, log, table)
                let service = try! MountService(
                    backends: [nfs],
                    store: MemoryStore(log),
                    table: table,
                    newID: { "rec" }
                )
                let listener = AgentListener(dispatcher: AgentDispatcher(service: service, mounts: "/Mounts"))
                let probe = DescriptorProbe()
                do throws(MountError) {
                    _ = try AgentConnection.withClient(endpoint: listener.endpoint) { client throws(MountError) in
                        try client.mount(source: "/i/a.img", kind: .nfs, at: "/m/a", descriptor: probe.descriptor)
                    }
                } catch {
                    exit(3)
                }
                let handed = nfs.descriptors.withLock { $0 }
                guard handed.count == 1, handed[0] != probe.descriptor else { exit(4) }
                var mine = stat()
                var theirs = stat()
                guard fstat(probe.descriptor, &mine) == 0, fstat(handed[0], &theirs) == 0,
                    mine.st_dev == theirs.st_dev, mine.st_ino == theirs.st_ino
                else { exit(5) }
                guard !probe.isClosed else { exit(6) }
                withExtendedLifetime(listener) {}
            }
        }
    }
}
