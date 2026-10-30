import Btrfs
import ExtFS
public import FSCore
import NTFS
import XFS

/// The formats MacFS reads, and how each is recognized and opened.
///
/// Probing opens the volume for real (superblock, chunk tree, MFT bootstrap): that is cheap, and a
/// volume that probes is then known to mount. A magic number alone is not evidence.
public enum DiskFormat: String, CaseIterable, Sendable {
    case btrfs
    case ntfs
    case ext
    case xfs

    /// The `mount -t` name and FSKit `FSShortName`. Never one macOS already uses: the system's own
    /// read-only `ntfs` would otherwise be shadowed or shadow this one (ADR-0006).
    public var shortName: String {
        switch self {
            case .btrfs: "btrfs"
            case .ntfs: "ntfsro"
            case .ext: "ext4"
            case .xfs: "xfs"
        }
    }

    /// The FSKit module's target and directory name (`Extensions/<name>`), and its bundle identifier.
    public var moduleName: String {
        switch self {
            case .btrfs: "BtrfsFS"
            case .ntfs: "NTFSFS"
            case .ext: "ExtFSModule"
            case .xfs: "XFSModule"
        }
    }

    public var moduleBundleIdentifier: String { "dev.gcqd.MacFS.\(moduleName)" }

    public var displayName: String {
        switch self {
            case .btrfs: "Btrfs"
            case .ntfs: "NTFS"
            case .ext: "ext2/3/4"
            case .xfs: "XFS"
        }
    }

    public func open(_ source: any BlockSource) throws(DiskError) -> any ReadOnlyFileSystem {
        switch self {
            case .btrfs: try BtrfsFileSystem(source: source)
            case .ntfs: try NTFSFileSystem(source: source)
            case .ext: try ExtFileSystem(source: source)
            case .xfs: try XFSFileSystem(source: source)
        }
    }

    private func hasMagic(_ source: any BlockSource) -> Bool {
        switch self {
            case .btrfs: BtrfsFileSystem.probe(source) != nil
            case .ntfs: NTFSFileSystem.probe(source)
            case .ext: ExtFileSystem.probe(source)
            case .xfs: XFSFileSystem.probe(source)
        }
    }

    /// The volume's description when `source` holds this format and opens.
    public func probe(_ source: any BlockSource) -> VolumeDescription? {
        guard hasMagic(source) else { return nil }
        return (try? open(source))?.volume
    }

    public static func detect(_ source: any BlockSource) -> DiskFormat? {
        allCases.first { $0.probe(source) != nil }
    }
}
