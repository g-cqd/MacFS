import MountKit
import Synchronization

/// Everything the fakes did, in order, shared by the backends, the table and the store of one test.
final class MountLog: Sendable {
    let events = Mutex<[String]>([])
    func add(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
}

/// The system's mount table, as the fakes leave it.
final class FakeMountTable: MountTable {
    let mounted = Mutex<[MountTableEntry]>([])
    func entries() -> [MountTableEntry] { mounted.withLock { $0 } }
    func canonical(_ path: String) -> String { path }
    func add(_ entry: MountTableEntry) { mounted.withLock { $0.append(entry) } }
    func remove(_ mountPoint: String) { mounted.withLock { $0.removeAll { $0.mountPoint == mountPoint } } }
}

/// A backend that mounts by adding a table entry `fake-<kind>:<source>`.
final class FakeBackend: MountBackend {
    let kind: MountBackendKind
    let log: MountLog
    let table: FakeMountTable
    let unavailable: String?
    let failMount = Mutex(false)
    let failUnmount = Mutex(false)
    /// Ids it serves: a mount whose server died is no longer here.
    let serving = Mutex<Set<String>>([])
    /// Called during `mount`, so a test can see what was recorded before the attempt.
    let duringMount = Mutex<(@Sendable () -> Void)?>(nil)

    init(_ kind: MountBackendKind, _ log: MountLog, _ table: FakeMountTable, unavailable: String? = nil) {
        self.kind = kind
        self.log = log
        self.table = table
        self.unavailable = unavailable
    }

    func availability(of source: String) -> MountAvailability {
        unavailable.map { .unavailable($0) } ?? .available
    }

    func mount(_ request: MountRequest) throws(MountError) -> String {
        log.add("mount \(kind) \(request.mountPoint)")
        duringMount.withLock { $0 }?()
        if failMount.withLock({ $0 }) { throw .backend("\(kind) refused") }
        let from = "fake-\(kind):\(request.source)"
        table.add(MountTableEntry(mountPoint: request.mountPoint, mountedFrom: from, type: "fake"))
        serving.withLock { _ = $0.insert(request.id) }
        return from
    }

    func unmount(_ record: MountRecord) throws(MountError) {
        log.add("unmount \(kind) \(record.mountPoint)")
        if failUnmount.withLock({ $0 }) { throw .backend("\(kind) busy") }
        table.remove(record.mountPoint)
        serving.withLock { _ = $0.remove(record.id) }
    }

    func forget(_ record: MountRecord) { log.add("forget \(kind) \(record.mountPoint)") }

    func isServing(_ record: MountRecord) -> Bool { serving.withLock { $0.contains(record.id) } }

    func claims(_ entry: MountTableEntry) -> Bool { entry.mountedFrom.hasPrefix("fake-\(kind):") }
}

/// The registry in memory; every save is logged, and can be made to fail.
final class MemoryStore: MountRegistryStore {
    let records = Mutex<[MountRecord]>([])
    let log: MountLog
    let failSave = Mutex(false)

    init(_ log: MountLog, _ records: [MountRecord] = []) {
        self.log = log
        self.records.withLock { $0 = records }
    }

    func load() throws(MountError) -> [MountRecord] { records.withLock { $0 } }

    func save(_ records: [MountRecord]) throws(MountError) {
        if failSave.withLock({ $0 }) { throw .registry("disk full") }
        log.add("save \(records.map { "\($0.mountPoint)=\($0.state)" }.joined(separator: ","))")
        self.records.withLock { $0 = records }
    }
}
