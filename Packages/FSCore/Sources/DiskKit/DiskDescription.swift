public import Formats

/// A disk or partition macOS attached, from its Disk Arbitration description (roadmap 0021, research 2026-11-01-disks-from-the-app).
///
/// Who reads it comes from the volume kind macOS found by probing, mounted or not: our modules report their short name (`ext4`,
/// `btrfs`, `xfs`); NTFS is Apple's own reader (`ntfs`), which ours (`ntfsro`) also reads. Without a kind, a partition map or an
/// APFS container holds volumes, and a Linux partition might hold one MacFS reads.
public struct DiskDescription: Sendable, Hashable, Identifiable {
    public struct Volume: Sendable, Hashable {
        public let kind: String
        public let name: String
        /// Where it is mounted; nil when it is not.
        public let path: String?

        public init(kind: String, name: String, path: String?) {
            self.kind = kind
            self.name = name
            self.path = path
        }
    }

    /// Who reads it.
    public enum Reader: Sendable, Hashable {
        /// One of our modules, by its short name.
        case macFS(DiskFormat)
        /// macOS's own reader; `alsoMacFS` when one of our modules reads the format too.
        case macOS(kind: String, alsoMacFS: DiskFormat?)
        /// No file system macOS knows, on a Linux partition: perhaps one MacFS reads.
        case mightBeMacFS
        /// A partition map or an APFS container: it holds volumes.
        case container
        case unknown
    }

    /// The BSD name (`disk9s1`).
    public let id: String
    public let isWhole: Bool
    public let size: Int64
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isWritable: Bool
    public let isInternal: Bool
    /// The partition type, or the whole disk's partition scheme (`GUID_partition_scheme`); empty for an unpartitioned disk.
    public let content: String
    public let isLeaf: Bool
    public let volume: Volume?

    /// Nil without a BSD name: then it is not a disk this app can act on.
    public init?(_ values: [String: DiskValue]) {
        guard let id = values["DAMediaBSDName"]?.text else { return nil }
        func flag(_ key: String) -> Bool { values[key]?.flag ?? false }
        self.id = id
        isWhole = flag("DAMediaWhole")
        size = values["DAMediaSize"]?.number ?? 0
        isRemovable = flag("DAMediaRemovable")
        isEjectable = flag("DAMediaEjectable")
        isWritable = flag("DAMediaWritable")
        isInternal = flag("DADeviceInternal")
        content = values["DAMediaContent"]?.text ?? ""
        isLeaf = flag("DAMediaLeaf")
        volume = values["DAVolumeKind"]?.text
            .map { kind in
                Volume(kind: kind, name: values["DAVolumeName"]?.text ?? "", path: values["DAVolumePath"]?.text)
            }
    }

    /// The whole disk a partition is on (`disk9` for `disk9s1`); nil for a whole disk.
    public var parent: String? {
        guard let index = id.lastIndex(of: "s"), id[id.index(after: index)...].allSatisfy(\.isNumber) else {
            return nil
        }
        return String(id[..<index])
    }

    public var reader: Reader {
        if let kind = volume?.kind {
            if let format = DiskFormat.allCases.first(where: { $0.shortName == kind }) { return .macFS(format) }
            return .macOS(kind: kind, alsoMacFS: Self.alsoOurs[kind])
        }
        // Recorded: a GPT whole disk, the APFS partition the container sits on and the container itself are none of them leaves.
        if !isLeaf { return .container }
        if Self.linux.contains(content) { return .mightBeMacFS }
        return .unknown
    }

    /// macOS's own kinds whose format one of our modules also reads.
    static let alsoOurs: [String: DiskFormat] = ["ntfs": .ntfs]

    /// Linux partition types that hold a file system: GPT's Linux data, root (x86-64, arm64), home and server data, and MBR's
    /// 0x83 as Disk Arbitration names it. Not swap, LVM or RAID, which hold none MacFS reads.
    static let linux: Set<String> = [
        "0FC63DAF-8483-4772-8E79-3D69D8477DE4", "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709",
        "B921B045-1DF0-41C3-AF44-4C6F280D3FAE", "933AC7E1-2EB4-4F13-B844-0E14E2AEF915",
        "3B8F8425-20E0-4F3B-907F-1A25A76F98E8", "Linux"
    ]
}
