import AemiProtobuf
import Darwin
import MountKit
import Synchronization
import Testing

@testable import MountAgent

/// The agent's protocol (roadmap 0039, ADR-0015), end to end in one process: the typed client, the byte transport XPC will
/// carry, the dispatcher, the service, fake backends. XPC adds framing and the peer requirement, checked live.
@Suite struct AgentProtocolTests {
    let log = MountLog()
    let table = FakeMountTable()
    let nfs: FakeBackend
    let store: MemoryStore
    let dispatcher: AgentDispatcher
    var client: AgentClient { AgentClient { [dispatcher] in dispatcher.handle($0, descriptor: $1) } }

    init() throws {
        nfs = FakeBackend(.nfs, log, table)
        store = MemoryStore(log)
        let webDAV = FakeBackend(.webDAV, log, table, unavailable: "not built yet")
        let counter = Mutex(0)
        dispatcher = AgentDispatcher(
            service: try MountService(
                backends: [nfs, webDAV],
                store: store,
                table: table,
                newID: {
                    let next = counter.withLock { value in
                        value += 1
                        return value
                    }
                    return next == 1 ? "rec" : "rec\(next)"
                }
            ),
            mounts: "/Mounts"
        )
    }

    @Test func mountListAndUnmountGoThroughTheAgent() throws {
        let record = try client.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        #expect(record.state == .mounted && record.mountedFrom == "fake-nfs:/i/a.img" && record.id == "rec")
        #expect(try client.list() == [record])
        try client.unmount(id: record.id)
        #expect(try client.list().isEmpty)
        #expect(log.all.filter { !$0.hasPrefix("save") } == ["mount nfs /m/a", "unmount nfs /m/a"])
    }

    /// The service's errors arrive as the same errors on the app's side.
    @Test func errorsCrossTheBoundaryIntact() throws {
        #expect(throws: MountError.unavailable(.webDAV, "not built yet")) {
            try client.mount(source: "/i/a.img", kind: .webDAV, at: "/m/a")
        }
        #expect(throws: MountError.noBackend(.fileProvider)) {
            try client.mount(source: "/i", kind: .fileProvider, at: "/m")
        }
        #expect(throws: MountError.notFound("nope")) { try client.unmount(id: "nope") }
        nfs.failMount.withLock { $0 = true }
        #expect(throws: MountError.backend("nfs refused")) {
            try client.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        }
        nfs.failMount.withLock { $0 = false }
        let mounted = try client.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        #expect(throws: MountError.mountPointInUse("/m/a")) {
            try client.mount(source: "/i/b.img", kind: .nfs, at: "/m/a")
        }
        store.failSave.withLock { $0 = true }
        #expect(throws: MountError.registry("disk full")) { try client.unmount(id: mounted.id) }
    }

    @Test func aSweepReportsWhatItDid() throws {
        let record = try client.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        table.remove("/m/a")
        let report = try client.sweep()
        #expect(report.forgotten == [record.id] && report.kept.isEmpty && !report.unsaved)
        _ = try client.mount(source: "/i/b.img", kind: .nfs, at: "/m/b")
        table.remove("/m/b")
        store.failSave.withLock { $0 = true }
        #expect(try client.sweep().unsaved, "a sweep that could not save says so across the boundary")
    }

    /// A newer app asks an older agent for an operation it does not know: refused by number, never guessed.
    @Test func anUnknownOperationIsRefusedByNumber() throws {
        let request = AgentRequest(operation: 42)
        let reply = try ProtobufDecoder()
            .decode(
                AgentReply.self,
                fromBytes: dispatcher.handle(try ProtobufEncoder().encodeToBytes(request), descriptor: nil)
            )
        #expect(reply.errorCode == AgentReply.Code.unsupported.rawValue)
        #expect(reply.error == "operation 42 is not known to this agent (protocol 1)")
        #expect(log.all.isEmpty)
    }

    @Test func aRequestThatIsNotOneIsRefused() throws {
        let reply = try ProtobufDecoder()
            .decode(AgentReply.self, fromBytes: dispatcher.handle([0xFF, 0xFF, 0xFF], descriptor: nil))
        #expect(reply.errorCode == AgentReply.Code.malformed.rawValue)
        #expect(throws: MountError.agent("the agent's reply is not one")) {
            try AgentClient { _, _ in [0xFF, 0xFF] }.list()
        }
    }

    /// Records of a kind this side does not know keep their number across the boundary (ADR-0015).
    @Test func unrecognizedKindsCrossTheBoundary() throws {
        let newer = MountRecord(
            id: "n",
            kind: .unrecognized(9),
            source: "/i",
            mountPoint: "/m/n",
            mountedFrom: "x",
            state: .unrecognized(5)
        )
        store.records.withLock { $0 = [newer] }
        let dispatcher = AgentDispatcher(
            service: try MountService(backends: [nfs], store: store, table: table, newID: { "x" }),
            mounts: "/Mounts"
        )
        #expect(try AgentClient { dispatcher.handle($0, descriptor: $1) }.list() == [newer])
        #expect(throws: MountError.unrecognized("n"), "and nothing acts on them") {
            try AgentClient { dispatcher.handle($0, descriptor: $1) }.unmount(id: "n")
        }
    }

    /// A transport that fails (the agent is not running, the peer requirement refused us) is an agent error, not a crash.
    @Test func aFailedTransportIsAnAgentError() {
        struct Down: Error {}
        #expect(throws: MountError.agent("Down()")) { try AgentClient { _, _ in throw Down() }.list() }
    }

    /// The sandboxed app sends the image it opened, and no mount point (its home is a container): the backend gets the
    /// descriptor, and the agent picks a point under its own `Mounts`, named after the image, the next free one if taken.
    @Test func theAppsDescriptorReachesTheBackendAndTheAgentPicksTheMountPoint() throws {
        let probe = DescriptorProbe()
        let first = try client.mount(
            source: "/Users/u/Downloads/Debian 12.img",
            kind: .nfs,
            at: "",
            descriptor: probe.descriptor
        )
        #expect(first.mountPoint == "/Mounts/Debian 12")
        #expect(nfs.descriptors.withLock { $0 } == [probe.descriptor])
        let second = try client.mount(source: "/elsewhere/Debian 12.img", kind: .nfs, at: "")
        #expect(second.mountPoint == "/Mounts/Debian 12 2")
        let odd = try client.mount(source: "/i/a:b/.hidden", kind: .nfs, at: "")
        #expect(odd.mountPoint == "/Mounts/.hidden", "the last component, whatever it holds")
        probe.closeDescriptor()
    }

    /// A descriptor sent with a request that does not mount is closed by the agent: nothing else would.
    @Test func aDescriptorWithAnotherRequestIsClosed() throws {
        let probe = DescriptorProbe()
        let request = try ProtobufEncoder().encodeToBytes(AgentRequest(operation: AgentRequest.Operation.list.rawValue))
        _ = dispatcher.handle(request, descriptor: probe.descriptor)
        #expect(probe.isClosed)
        let unknown = DescriptorProbe()
        _ = dispatcher.handle(
            try ProtobufEncoder().encodeToBytes(AgentRequest(operation: 42)),
            descriptor: unknown.descriptor
        )
        #expect(unknown.isClosed, "nor with one it refuses")
        let garbage = DescriptorProbe()
        _ = dispatcher.handle([0xFF], descriptor: garbage.descriptor)
        #expect(garbage.isClosed, "nor with bytes that are not a request")
    }
}
