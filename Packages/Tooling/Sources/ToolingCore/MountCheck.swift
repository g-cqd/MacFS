import Formats
import Foundation

/// The end-to-end check (roadmap 0025): each test image attached without mounting, mounted read-only through its FSKit module
/// (`mount -F`, which needs the modules installed and enabled), compared with its manifest, refused a write, unmounted and
/// detached. The volume is always released, whatever failed before.
public struct MountCheck: Sendable {
    public struct Target: Sendable, Equatable {
        public let image: String
        public let type: String
        public let extra: Set<String>
        public init(image: String, type: String, extra: Set<String>) {
            self.image = image
            self.type = type
            self.extra = extra
        }
    }

    public struct Outcome: Sendable {
        public let target: Target
        public let problems: [String]
        public init(target: Target, problems: [String]) {
            self.target = target
            self.problems = problems
        }
    }

    /// Every test image a module reads whole. Not here: ext4-gpt (its attach yields the disk and its partition).
    public static let targets: [Target] = {
        let ext = [
            "ext2", "ext3", "ext4", "ext4-inline", "ext4-bigalloc", "ext4-uuid-seed", "ext4-meta-bg", "ext4-grown"
        ]
        .map {
            Target(image: $0, type: DiskFormat.ext.shortName, extra: ["lost+found"])
        }
        let btrfs = ["btrfs", "btrfs-zlib", "btrfs-lzo", "btrfs-zstd", "btrfs-xxhash", "btrfs-subvol"]
            .map {
                Target(image: $0, type: DiskFormat.btrfs.shortName, extra: [])
            }
        let ntfs = ["ntfs", "ntfs-lznt1"].map { Target(image: $0, type: DiskFormat.ntfs.shortName, extra: []) }
        let xfs = ["xfs", "xfs-1k"].map { Target(image: $0, type: DiskFormat.xfs.shortName, extra: []) }
        return ext + btrfs + ntfs + xfs
    }()

    let runner: any ProcessRunning
    let root: String
    let mountPoint: @Sendable (Target) -> String
    let verification: MountVerification
    /// Waits before the retry; the tests' does not.
    let pause: @Sendable (Duration) -> Void

    public init(
        runner: any ProcessRunning,
        root: String,
        mountPoint: @escaping @Sendable (Target) -> String,
        verification: MountVerification,
        pause: @escaping @Sendable (Duration) -> Void
    ) {
        self.runner = runner
        self.root = root
        self.mountPoint = mountPoint
        self.verification = verification
        self.pause = pause
    }

    public func run(_ target: Target) -> Outcome {
        let image = "\(root)/TestImages/\(target.image)"
        let point = mountPoint(target)
        let session = MountSession(runner: runner, pause: pause)
        let (problems, _) = session.run(
            image: "\(image).img",
            attach: ["-readonly"],
            type: target.type,
            mount: ["-o", "rdonly"],
            at: point
        ) { verification.problems(at: point, manifest: "\(image).manifest", extra: target.extra) }
        return Outcome(target: target, problems: problems)
    }

    /// Whether creating a file at the root of `point` fails, as on a read-only mount; a file that was created is removed.
    public static func refusesWrites(at point: String) -> Bool {
        let probe = URL(fileURLWithPath: point).appendingPathComponent(".macfs-write-probe")
        guard (try? Data().write(to: probe, options: .withoutOverwriting)) != nil else { return true }
        try? FileManager.default.removeItem(at: probe)
        return false
    }

    /// The whole-disk device `hdiutil attach` reports first.
    static func device(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("/dev/disk") }.map(String.init)
    }
}
