import MountKit
import Synchronization
import Testing

/// The mount seam (roadmap 0035, ADR-0013): every mount recorded before it is attempted, an unmount routed to the backend that
/// mounted, no silent substitution, make before break, and a sweep that touches only mounts it can prove are MacFS's.
@Suite struct MountServiceTests {
    let log = MountLog()
    let table = FakeMountTable()
    let nfs: FakeBackend
    let fsKit: FakeBackend
    let webDAV: FakeBackend
    let store: MemoryStore
    let service: MountService

    init() throws {
        nfs = FakeBackend(.nfs, log, table)
        fsKit = FakeBackend(.fsKit, log, table)
        webDAV = FakeBackend(.webDAV, log, table, unavailable: "the WebDAV backend is not built yet (roadmap 0008)")
        store = MemoryStore(log)
        let counter = Mutex(0)
        service = try MountService(
            backends: [nfs, fsKit, webDAV],
            store: store,
            table: table,
            newID: {
                let next = counter.withLock { value in
                    value += 1
                    return value
                }
                return "id\(next)"
            }
        )
    }

    @Test func aMountIsRecordedBeforeItIsAttemptedAndMarkedOnceItIsUp() throws {
        let seen = Mutex<[MountRecord]>([])
        let store = store
        nfs.duringMount.withLock { $0 = { seen.withLock { $0 = store.records.withLock { $0 } } } }
        let record = try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        #expect(seen.withLock { $0 }.map(\.state) == [.pending], "the attempt is on record before it is made")
        #expect(record.state == .mounted && record.mountedFrom == "fake-nfs:/i/a.img" && record.kind == .nfs)
        #expect(service.records() == [record])
        #expect(store.records.withLock { $0 } == [record])
    }

    @Test func aFailedMountLeavesNoRecord() throws {
        nfs.failMount.withLock { $0 = true }
        #expect(throws: MountError.backend("nfs refused")) {
            try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        }
        #expect(service.records().isEmpty && store.records.withLock { $0 }.isEmpty)
    }

    /// A registry that cannot be written means nothing is mounted: a mount without a record could never be swept.
    @Test func noRecordNoMount() {
        store.failSave.withLock { $0 = true }
        #expect(throws: MountError.registry("disk full")) {
            try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        }
        #expect(!log.all.contains { $0.hasPrefix("mount") })
    }

    /// Everest mounts a stored FSKit choice with WebDAV, unannounced. Here the backend says why, and nothing else is tried.
    @Test func anUnavailableBackendSaysWhyAndNothingIsSubstituted() {
        #expect(throws: MountError.unavailable(.webDAV, "the WebDAV backend is not built yet (roadmap 0008)")) {
            try service.mount(source: "/i/a.img", kind: .webDAV, at: "/m/a")
        }
        #expect(throws: MountError.noBackend(.fileProvider)) {
            try service.mount(source: "/i/a.img", kind: .fileProvider, at: "/m/a")
        }
        #expect(log.all.isEmpty)
    }

    @Test func aMountPointHoldsOneMount() throws {
        _ = try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        #expect(throws: MountError.mountPointInUse("/m/a")) {
            try service.mount(source: "/i/b.img", kind: .fsKit, at: "/m/a")
        }
        table.add(MountTableEntry(mountPoint: "/m/other", mountedFrom: "/dev/disk9s1", type: "apfs"))
        #expect(throws: MountError.mountPointInUse("/m/other")) {
            try service.mount(source: "/i/b.img", kind: .nfs, at: "/m/other")
        }
    }

    @Test func anUnmountGoesToTheBackendThatMounted() throws {
        let a = try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        let b = try service.mount(source: "/i/b.img", kind: .fsKit, at: "/m/b")
        try service.unmount(id: a.id)
        try service.unmount(id: b.id)
        #expect(log.all.filter { $0.hasPrefix("unmount") } == ["unmount nfs /m/a", "unmount fsKit /m/b"])
        #expect(service.records().isEmpty)
    }

    /// A mount already gone (the kernel unmounted a dead proxy, or the user ran `umount`) is cleared, not an error.
    @Test func anUnmountOfAMountAlreadyGoneClearsItsRecord() throws {
        let a = try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        table.remove("/m/a")
        nfs.failUnmount.withLock { $0 = true }
        try service.unmount(id: a.id)
        #expect(service.records().isEmpty)
    }

    /// Ours was ejected and another mount took the point: the backend refuses to touch it, and our record goes.
    @Test func anUnmountWhoseMountWasReplacedClearsItsRecord() throws {
        let a = try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        table.remove("/m/a")
        table.add(MountTableEntry(mountPoint: "/m/a", mountedFrom: "/dev/disk6s1", type: "apfs"))
        nfs.failUnmount.withLock { $0 = true }
        try service.unmount(id: a.id)
        #expect(service.records().isEmpty)
    }

    /// A busy mount stays mounted and on record.
    @Test func aFailedUnmountKeepsTheRecord() throws {
        let a = try service.mount(source: "/i/a.img", kind: .nfs, at: "/m/a")
        nfs.failUnmount.withLock { $0 = true }
        #expect(throws: MountError.backend("nfs busy")) { try service.unmount(id: a.id) }
        #expect(service.records() == [a])
        #expect(throws: MountError.notFound("nope")) { try service.unmount(id: "nope") }
    }

    /// Make before break: the new mount comes up first; the old one goes only once it has. Everest breaks first.
    @Test func changingBackendMakesBeforeBreaking() throws {
        let a = try service.mount(source: "/i/a.img", kind: .fsKit, at: "/m/a")
        let change = try service.change(id: a.id, to: .nfs, at: "/m/a2")
        #expect(Array(log.all.filter { !$0.hasPrefix("save") }.suffix(2)) == ["mount nfs /m/a2", "unmount fsKit /m/a"])
        #expect(change.oldUnmounted && change.record.kind == .nfs && change.record.source == "/i/a.img")
        #expect(service.records() == [change.record])
    }

    @Test func aFailedChangeLeavesTheOldMountAsItWas() throws {
        let a = try service.mount(source: "/i/a.img", kind: .fsKit, at: "/m/a")
        nfs.failMount.withLock { $0 = true }
        #expect(throws: MountError.backend("nfs refused")) { try service.change(id: a.id, to: .nfs, at: "/m/a2") }
        #expect(service.records() == [a])
        #expect(!log.all.contains("unmount fsKit /m/a"))
    }

    /// When the old mount will not go, both stay on record (the sweep or the user ends it) and the caller is told.
    @Test func aChangeWhoseOldMountStaysSaysSo() throws {
        let a = try service.mount(source: "/i/a.img", kind: .fsKit, at: "/m/a")
        fsKit.failUnmount.withLock { $0 = true }
        let change = try service.change(id: a.id, to: .nfs, at: "/m/a2")
        #expect(!change.oldUnmounted)
        #expect(Set(service.records().map(\.id)) == [a.id, change.record.id])
    }

    // MARK: - Sweep

    /// Launch, after a crash: each record checked against the mount table and its backend.
    @Test func theSweepTouchesOnlyWhatItCanProveIsMacFSs() throws {
        let live = try service.mount(source: "/i/live.img", kind: .nfs, at: "/m/live")
        let dead = try service.mount(source: "/i/dead.img", kind: .nfs, at: "/m/dead")
        let gone = try service.mount(source: "/i/gone.img", kind: .fsKit, at: "/m/gone")
        let replaced = try service.mount(source: "/i/r.img", kind: .nfs, at: "/m/replaced")
        nfs.serving.withLock { _ = $0.remove(dead.id) }  // its server died with the old process
        table.remove("/m/gone")  // unmounted behind our back
        table.remove("/m/replaced")
        // someone else's now
        table.add(MountTableEntry(mountPoint: "/m/replaced", mountedFrom: "/dev/disk4s1", type: "apfs"))
        // not on record
        table.add(MountTableEntry(mountPoint: "/m/foreign", mountedFrom: "fake-nfs:/i/x.img", type: "fake"))
        let report = service.sweep()
        #expect(report.kept == [live.id])
        #expect(Set(report.unmounted) == [dead.id])
        #expect(Set(report.forgotten) == [gone.id, replaced.id])
        #expect(
            log.all.filter { $0.hasPrefix("unmount") } == ["unmount nfs /m/dead"],
            "never the foreign or the replaced mount"
        )
        #expect(
            log.all.filter { $0.hasPrefix("forget") } == ["forget fsKit /m/gone"],
            "the empty mount point of a mount gone, not one another mount holds"
        )
        #expect(service.records() == [live])
    }

    @Test func aSweepThatCannotSaveSaysSo() throws {
        let gone = try service.mount(source: "/i/gone.img", kind: .fsKit, at: "/m/gone")
        table.remove("/m/gone")
        store.failSave.withLock { $0 = true }
        let report = service.sweep()
        #expect(report.forgotten == [gone.id] && report.unsaved)
        #expect(service.records().isEmpty)
    }

    /// A crash between the record and the mount leaves a pending record: what is at its mount point is unmounted only if its
    /// backend claims it and does not serve it; otherwise the record is forgotten.
    @Test func theSweepSettlesPendingRecords() throws {
        let store = MemoryStore(
            log,
            [
                MountRecord(
                    id: "p1",
                    kind: .nfs,
                    source: "/i/a.img",
                    mountPoint: "/m/a",
                    mountedFrom: "",
                    state: .pending
                ),
                MountRecord(
                    id: "p2",
                    kind: .nfs,
                    source: "/i/b.img",
                    mountPoint: "/m/b",
                    mountedFrom: "",
                    state: .pending
                ),
                MountRecord(
                    id: "p3",
                    kind: .nfs,
                    source: "/i/c.img",
                    mountPoint: "/m/c",
                    mountedFrom: "",
                    state: .pending
                )
            ]
        )
        // it got mounted
        table.add(MountTableEntry(mountPoint: "/m/a", mountedFrom: "fake-nfs:/i/a.img", type: "fake"))
        table.add(MountTableEntry(mountPoint: "/m/b", mountedFrom: "/dev/disk5s1", type: "apfs"))  // not ours
        let service = try MountService(backends: [nfs, fsKit], store: store, table: table, newID: { "x" })
        let report = service.sweep()
        #expect(report.unmounted == ["p1"])
        #expect(Set(report.forgotten) == ["p2", "p3"])
        #expect(service.records().isEmpty)
        #expect(table.entries().map(\.mountPoint) == ["/m/b"])
    }

    /// A record written by a newer version (a backend this one does not know) is kept as it is, and nothing acts on it
    /// (ADR-0015): an older agent must not route a WebDAV mount's unmount to FSKit.
    @Test func recordsOfAnUnrecognizedKindAreKeptAndNotActedOn() throws {
        let newer = MountRecord(
            id: "n1",
            kind: .unrecognized(9),
            source: "/i/a.img",
            mountPoint: "/m/a",
            mountedFrom: "x",
            state: .mounted
        )
        let store = MemoryStore(log, [newer])
        let service = try MountService(backends: [nfs, fsKit], store: store, table: table, newID: { "x" })
        #expect(service.sweep().skipped == ["n1"])
        #expect(throws: MountError.unrecognized("n1")) { try service.unmount(id: "n1") }
        #expect(service.records() == [newer])
        #expect(!log.all.contains { $0.hasPrefix("unmount") })
    }

    @Test func kindsHaveStableNumbers() {
        #expect(MountBackendKind.allKnown.map(\.rawValue) == [0, 1, 2, 3])
        #expect(MountBackendKind(rawValue: 1) == .nfs && MountBackendKind(rawValue: 7) == .unrecognized(7))
        #expect(MountRecord.State(rawValue: 1) == .mounted && MountRecord.State(rawValue: 5) == .unrecognized(5))
    }
}
