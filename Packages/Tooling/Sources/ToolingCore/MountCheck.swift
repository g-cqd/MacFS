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
    let compare: @Sendable (String, String, Set<String>) throws -> [String]
    let writeRefused: @Sendable (String) -> Bool

    public init(
        runner: any ProcessRunning,
        root: String,
        mountPoint: @escaping @Sendable (Target) -> String,
        compare: @escaping @Sendable (String, String, Set<String>) throws -> [String],
        writeRefused: @escaping @Sendable (String) -> Bool
    ) {
        self.runner = runner
        self.root = root
        self.mountPoint = mountPoint
        self.compare = compare
        self.writeRefused = writeRefused
    }

    public func run(_ target: Target) -> Outcome {
        let image = "\(root)/TestImages/\(target.image)"
        guard
            let attach = try? runner.run(
                Command("/usr/bin/hdiutil", ["attach", "-nomount", "-readonly", "\(image).img"])
            ),
            attach.status == 0, let device = Self.device(attach.output)
        else { return Outcome(target: target, problems: ["attach: no device for \(image).img"]) }
        var problems: [String] = []
        let point = mountPoint(target)
        let mount = try? runner.run(Command("/sbin/mount", ["-F", "-t", target.type, "-o", "rdonly", device, point]))
        if let mount, mount.status == 0 {
            do { problems += try compare(point, "\(image).manifest", target.extra) } catch {
                problems.append("compare: \(error)")
            }
            if !writeRefused(point) { problems.append("a write was accepted on a read-only mount") }
            _ = try? runner.run(Command("/sbin/umount", [point]))
        } else {
            problems.append("mount -t \(target.type): \(mount?.output ?? "did not run")")
        }
        _ = try? runner.run(Command("/usr/bin/hdiutil", ["detach", device]))
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
