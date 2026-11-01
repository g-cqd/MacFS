/// The disks attached now, as the watcher's events left them: whole disks, each with its partitions, in numeric order.
public struct DiskList: Sendable, Hashable {
    private var disks: [String: DiskDescription] = [:]

    public init() {}

    public mutating func apply(_ event: DiskEvent) {
        switch event {
            case .appeared(let disk), .changed(let disk): disks[disk.id] = disk
            case .disappeared(let id): disks[id] = nil
        }
    }

    public var wholeDisks: [DiskDescription] { Self.ordered(disks.values.filter(\.isWhole)) }

    public func partitions(of whole: String) -> [DiskDescription] {
        Self.ordered(disks.values.filter { $0.parent == whole })
    }

    /// `disk2` before `disk10`, `disk9s2` before `disk9s10`.
    private static func ordered(_ disks: [DiskDescription]) -> [DiskDescription] {
        disks.sorted { numbers($0.id).lexicographicallyPrecedes(numbers($1.id)) }
    }

    /// The numbers in a BSD name: `disk9s10` is [9, 10].
    private static func numbers(_ id: String) -> [Int] {
        id.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
