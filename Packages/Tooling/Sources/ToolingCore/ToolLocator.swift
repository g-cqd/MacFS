/// Finds the gates' tools: `MACFS_<NAME>` first, then pinned install locations, then `PATH`.
///
/// The analyzers are pinned by the family's lock (`Scripts/analyzers.lock`) and found where aemi's `analyzers.sh` and
/// `macfs-tool analyzers` install them, `~/Library/Caches/g-cqd-analyzers/<tool>-<version>/` (roadmap 0010).
public struct ToolLocator: Sendable {
    public struct Missing: Error, Equatable {
        public let tools: [String]
        public init(tools: [String]) { self.tools = tools }
    }

    private let environment: [String: String]
    private let home: String
    private let lock: AnalyzerLock?
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        environment: [String: String],
        home: String,
        lock: AnalyzerLock? = nil,
        isExecutable: @escaping @Sendable (String) -> Bool
    ) {
        self.environment = environment
        self.home = home
        self.lock = lock
        self.isExecutable = isExecutable
    }

    /// The shared install directory of a locked tool.
    public static func installDirectory(_ pin: AnalyzerLock.Pin, home: String) -> String {
        "\(home)/Library/Caches/g-cqd-analyzers/\(pin.tool)-\(pin.version)"
    }

    public func find(_ name: String, pinned: [String] = []) -> String? {
        let key = "MACFS_" + name.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        if let override = environment[String(key)], isExecutable(override) { return override }
        if let hit = pinned.first(where: isExecutable) { return hit }
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        return path.map { "\($0)/\(name)" }.first(where: isExecutable)
    }

    public func pinnedLocations(_ name: String) -> [String] {
        guard let pin = lock?[name] else { return [] }
        return ["\(Self.installDirectory(pin, home: home))/\(name)"]
    }

    public func gatePaths() throws(Missing) -> ToolPaths {
        var missing: [String] = []
        func need(_ name: String, pinned: [String]? = nil) -> String {
            if let found = find(name, pinned: pinned ?? pinnedLocations(name)) { return found }
            missing.append(name)
            return ""
        }
        let swift = need("swift", pinned: [])
        let swiftlint = need("swiftlint", pinned: [])
        let deadwood = need("deadwood")
        let dolly = need("dolly")
        let arcleak = need("arcleak")
        let fcheck = need("fcheck")
        let modeler = need("modeler")
        let java = need("java", pinned: [])
        let jar = need("tla2tools.jar", pinned: ["\(home)/.local/share/tla/tla2tools.jar"])
        let lake = need("lake", pinned: ["\(home)/.elan/bin/lake"])
        guard missing.isEmpty else { throw Missing(tools: missing) }
        return ToolPaths(
            swift: swift,
            swiftlint: swiftlint,
            deadwood: deadwood,
            dolly: dolly,
            arcleak: arcleak,
            fcheck: fcheck,
            modeler: modeler,
            java: java,
            tla2tools: jar,
            lake: lake
        )
    }
}
