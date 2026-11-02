public import FSCore

/// The modules' check (roadmap 0046), which Disk Arbitration runs before every mount of a writable device, automounts too:
/// `-q`, then `-y` when that fails, refusing the mount when the repair fails too (measured, diary 2026-11-02-02). `-q` passes a
/// readable volume and names its problems: the module writes none that records them, so it mounts read-only, as it did before
/// the check. A full check passes a volume that opens and records no inconsistency, whatever MacFS can write. Nothing is
/// repaired: a repair fails, naming the format's own tool.
public enum VolumeCheck {
    public struct Report: Sendable, Equatable {
        public let passed: Bool
        /// For the check's client, one line each.
        public let messages: [String]
    }

    /// Reads `source` only.
    public static func run(_ format: DiskFormat, on source: any BlockSource, options: [String]) -> Report {
        let problems: [String]
        do throws(DiskError) {
            problems = try format.open(source).consistencyProblems()
        } catch {
            return Report(passed: false, messages: ["the volume cannot be read: \(error)"])
        }
        guard !problems.isEmpty else {
            return Report(passed: true, messages: ["\(format.displayName): no problem found"])
        }
        let tool = repairTool(format)
        // Disk Arbitration's question before a mount: a readable volume mounts, and MacFS writes none that records problems.
        if quick(options) {
            return Report(passed: true, messages: problems + ["MacFS mounts it read-only until \(tool) repairs it"])
        }
        let advice =
            repairs(options)
            ? "MacFS does not repair \(format.displayName) volumes: run \(tool), then mount again"
            : "\(tool) repairs it"
        return Report(passed: false, messages: problems + [advice])
    }

    /// Whether the options ask only whether the volume can be mounted: `-q`, Disk Arbitration's first check.
    static func quick(_ options: [String]) -> Bool { flags(options).contains("q") && !repairs(options) }

    /// The letters of the short options.
    static func flags(_ options: [String]) -> Set<Character> {
        Set(options.filter { $0.hasPrefix("-") && !$0.hasPrefix("--") }.flatMap { $0.dropFirst() })
    }

    /// Whether the options ask for a repair: `-y` or `-p`, alone or among other letters.
    public static func repairs(_ options: [String]) -> Bool {
        !flags(options).isDisjoint(with: ["y", "p"])
    }

    /// The format's own repair tool.
    static func repairTool(_ format: DiskFormat) -> String {
        switch format {
            case .ext: "e2fsck (Linux)"
            case .xfs: "xfs_repair (Linux)"
            case .btrfs: "btrfs check --repair (Linux)"
            case .ntfs: "chkdsk (Windows)"
        }
    }
}
