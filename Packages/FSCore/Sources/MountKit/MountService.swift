import Synchronization

/// The one way MacFS mounts (ADR-0013): routes each request to the backend of its kind, keeps the registry as the truth (a
/// record before every attempt), makes before it breaks, and sweeps what a previous process left. Operations are serialized
/// and block on their backend: call them off any cooperative pool.
public final class MountService: Sendable {
    private let backends: [MountBackendKind: any MountBackend]
    private let store: any MountRegistryStore
    private let table: any MountTable
    private let newID: @Sendable () -> String
    private let state: Mutex<[MountRecord]>

    public init(
        backends: [any MountBackend],
        store: any MountRegistryStore,
        table: any MountTable,
        newID: @escaping @Sendable () -> String
    ) throws(MountError) {
        var byKind: [MountBackendKind: any MountBackend] = [:]
        for backend in backends { byKind[backend.kind] = backend }
        self.backends = byKind
        self.store = store
        self.table = table
        self.newID = newID
        state = Mutex(try store.load())
    }

    public func records() -> [MountRecord] { state.withLock { $0 } }

    public func mount(source: String, kind: MountBackendKind, at mountPoint: String) throws(MountError) -> MountRecord {
        try state.withLock { (records) throws(MountError) -> MountRecord in
            try mount(source: source, kind: kind, at: mountPoint, &records)
        }
    }

    public func unmount(id: String) throws(MountError) {
        try state.withLock { (records) throws(MountError) in try unmount(id: id, &records) }
    }

    /// Moves a mount to another backend at another mount point: the new one is mounted first, the old one unmounted after.
    public func change(id: String, to kind: MountBackendKind, at mountPoint: String) throws(MountError) -> MountChange {
        try state.withLock { (records) throws(MountError) -> MountChange in
            guard let old = records.first(where: { $0.id == id }) else { throw .notFound(id) }
            guard old.isRecognized else { throw .unrecognized(id) }
            let new = try mount(source: old.source, kind: kind, at: mountPoint, &records)
            do {
                try unmount(id: id, &records)
                return MountChange(record: new, oldUnmounted: true)
            } catch {
                return MountChange(record: new, oldUnmounted: false)
            }
        }
    }

    /// Settles every record against the mount table and its backend; mounts not on record are never touched.
    public func sweep() -> SweepReport {
        state.withLock { records in
            var report = SweepReport()
            var remaining: [MountRecord] = []
            for record in records {
                guard record.isRecognized, let backend = backends[record.kind] else {
                    report.skipped.append(record.id)
                    remaining.append(record)
                    continue
                }
                let entry = table.entries().first { $0.mountPoint == record.mountPoint }
                let ours: Bool
                switch record.state {
                    case .mounted: ours = entry?.mountedFrom == record.mountedFrom
                    case .pending, .unrecognized: ours = entry.map(backend.claims) ?? false
                }
                if !ours {
                    report.forgotten.append(record.id)
                    if entry == nil { backend.forget(record) }  // a point another mount holds is not ours to clean
                } else if record.state == .mounted, backend.isServing(record) {
                    report.kept.append(record.id)
                    remaining.append(record)
                } else {
                    var settled = record
                    settled.mountedFrom = entry?.mountedFrom ?? record.mountedFrom
                    do {
                        try backend.unmount(settled)
                        report.unmounted.append(record.id)
                    } catch {
                        report.failed.append(record.id)
                        remaining.append(record)
                    }
                }
            }
            if remaining != records {
                // Memory follows what was done; a registry that cannot be written is reported, and the next sweep settles it.
                records = remaining
                report.unsaved = (try? store.save(remaining)) == nil
            }
            return report
        }
    }

    // MARK: - Under the lock

    private func mount(
        source: String,
        kind: MountBackendKind,
        at path: String,
        _ records: inout [MountRecord]
    ) throws(MountError) -> MountRecord {
        guard let backend = backends[kind] else { throw .noBackend(kind) }
        if case .unavailable(let reason) = backend.availability(of: source) { throw .unavailable(kind, reason) }
        let mountPoint = table.canonical(path)
        let taken =
            records.contains { $0.mountPoint == mountPoint } || table.entries().contains { $0.mountPoint == mountPoint }
        guard !taken else { throw .mountPointInUse(path) }
        var record = MountRecord(
            id: newID(),
            kind: kind,
            source: source,
            mountPoint: mountPoint,
            mountedFrom: "",
            state: .pending
        )
        try store.save(records + [record])  // no record, no mount: an unrecorded mount could never be swept
        records.append(record)
        do {
            record.mountedFrom = try backend.mount(MountRequest(id: record.id, source: source, mountPoint: mountPoint))
        } catch {
            records.removeAll { $0.id == record.id }
            try? store.save(records)  // a pending record left behind is settled by the sweep
            throw error
        }
        record.state = .mounted
        records = records.map { $0.id == record.id ? record : $0 }
        try store.save(records)
        return record
    }

    private func unmount(id: String, _ records: inout [MountRecord]) throws(MountError) {
        guard let record = records.first(where: { $0.id == id }) else { throw .notFound(id) }
        guard record.isRecognized, let backend = backends[record.kind] else {
            throw record.isRecognized ? .noBackend(record.kind) : .unrecognized(id)
        }
        do {
            try backend.unmount(record)
        } catch {
            // Gone already (the kernel unmounted a dead proxy, or the user did): not an error.
            let present = table.entries()
                .contains {
                    $0.mountPoint == record.mountPoint && $0.mountedFrom == record.mountedFrom
                }
            if present { throw error }
        }
        let remaining = records.filter { $0.id != id }
        try store.save(remaining)
        records = remaining
    }
}
