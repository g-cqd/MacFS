import DiskKit
import Formats
import Testing

/// What a disk is, from its Disk Arbitration description (roadmap 0021), on descriptions recorded from the test images.
struct DiskDescriptionTests {
    static func disk(_ key: String) -> DiskDescription { DiskDescription(Recorded[key])! }

    /// The recordings load, all of them, each with its BSD name.
    @Test func theRecordingsLoad() {
        #expect(Recorded.descriptions.count == 24)
        #expect(Recorded.descriptions.values.allSatisfy { $0["DAMediaBSDName"] != nil })
    }

    /// Our modules name the volume kind with their short name, mounted or not: MacFS reads it, through that module.
    @Test(arguments: [
        ("ext2 nomount disk9", DiskFormat.ext), ("ext2 mounted disk9", .ext), ("ext4 nomount disk9", .ext),
        ("ext4 mounted disk9", .ext), ("ext4-gpt nomount disk9s1", .ext), ("ext4-gpt mounted disk9s1", .ext),
        ("btrfs nomount disk9", .btrfs), ("btrfs mounted disk9", .btrfs), ("xfs nomount disk9", .xfs),
        ("xfs mounted disk9", .xfs)
    ])
    func ourVolumesAreReadByOurModules(key: String, format: DiskFormat) {
        #expect(Self.disk(key).reader == .macFS(format))
    }

    /// macOS 27 mounts NTFS with its own reader (kind `ntfs`); ours (`ntfsro`) reads it too, when named.
    @Test func ntfsIsApplesAndOursToo() {
        #expect(Self.disk("ntfs mounted disk9").reader == .macOS(kind: "ntfs", alsoMacFS: .ntfs))
        #expect(Self.disk("ntfs nomount disk9").reader == .macOS(kind: "ntfs", alsoMacFS: .ntfs))
    }

    @Test func applesOwnVolumesAreApples() {
        #expect(Self.disk("exfat mounted disk9").reader == .macOS(kind: "exfat", alsoMacFS: nil))
        #expect(Self.disk("apfs nomount disk10s1").reader == .macOS(kind: "apfs", alsoMacFS: nil))
    }

    /// A partition map or an APFS container holds volumes; it is not one.
    @Test(arguments: [
        "ext4-gpt nomount disk9", "ext4-gpt mounted disk9", "apfs nomount disk10", "linux-blank nomount disk9",
        "apfs nomount physical disk9", "apfs nomount physical disk9s1"
    ])
    func containersAreNotVolumes(key: String) {
        #expect(Self.disk(key).reader == .container)
        #expect(Self.disk(key).volume == nil)
    }

    /// A Linux partition no file system macOS knows is on: MacFS might read it (its superblock may be damaged,
    /// or of a kind our modules refused).
    @Test func aLinuxPartitionWithoutAKnownVolumeMightBeOurs() {
        #expect(Self.disk("linux-blank nomount disk9s1").reader == .mightBeMacFS)
    }

    /// Without a known volume and without a Linux type, nothing says what it is.
    @Test func anUnknownPartitionIsUnknown() {
        var values = Recorded["linux-blank nomount disk9s1"]
        values["DAMediaContent"] = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"  // Microsoft basic data
        #expect(DiskDescription(values)?.reader == .unknown)
    }

    @Test func aDescriptionReadsItsDiskAndVolume() {
        let mounted = Self.disk("ext4-gpt mounted disk9s1")
        #expect(mounted.id == "disk9s1")
        #expect(!mounted.isWhole)
        #expect(mounted.parent == "disk9")
        #expect(mounted.size == 133_152_256)
        #expect(mounted.isRemovable && mounted.isEjectable && !mounted.isWritable && !mounted.isInternal)
        #expect(mounted.volume == DiskDescription.Volume(kind: "ext4", name: "ext4-gpt", path: "/Volumes/ext4-gpt"))
        #expect(Self.disk("ext4-gpt nomount disk9s1").volume?.path == nil)
        let whole = Self.disk("ext4-gpt mounted disk9")
        #expect(whole.isWhole)
        #expect(whole.parent == nil)
    }

    @Test func aDescriptionWithoutABSDNameIsNoDisk() {
        var values = Recorded["ext4 mounted disk9"]
        values["DAMediaBSDName"] = nil
        #expect(DiskDescription(values) == nil)
    }
}
