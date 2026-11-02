import FSCore
import Formats
import Testing

/// The modules' check (roadmap 0046): Disk Arbitration runs it before every mount of a writable device, automounts too: `-q`
/// first, `-y` when that fails, and refuses the mount when the repair fails too (measured). `-q` asks whether the volume can be
/// mounted: it passes a readable one and names its problems (the module will not write a volume that records them, so it
/// mounts read-only, as before the check existed). A full check (`-n`, `-y`, `-p`, none) fails a volume that records its own
/// inconsistency; nothing is repaired, and the format's own tool is named.
@Suite struct VolumeCheckTests {
    static func copy(_ name: String) throws -> MemoryBlockSource {
        let image = try ImageOracle.image(name)
        return MemoryBlockSource(try image.read(at: 0, count: Int(image.byteCount)))
    }

    /// The ext superblock's state (0x3A from 1024): bit 0 clean, bit 1 errors.
    static func setExtState(_ state: UInt16, on device: MemoryBlockSource) throws {
        try device.write(at: 1024 + 0x3A, [UInt8(state & 0xFF), UInt8(state >> 8)])
    }

    @Test(arguments: ["ext2", "ext4", "xfs", "btrfs", "ntfs"])
    func aConsistentVolumePassesEveryMode(_ name: String) throws {
        let device = try Self.copy(name)
        let format = try #require(DiskFormat.detect(device))
        for options in [["-q"], ["-n"], ["-y"], ["-p"], ["-f", "-n"]] {
            let report = VolumeCheck.run(format, on: device, options: options)
            #expect(report.passed, "\(name) \(options): \(report.messages)")
        }
    }

    @Test func aVolumeNotCleanlyUnmountedFailsAndIsNotRepaired() throws {
        let device = try Self.copy("ext2")
        try Self.setExtState(0, on: device)
        let quick = VolumeCheck.run(.ext, on: device, options: ["-q"])
        #expect(quick.passed, "readable: it mounts, read-only")
        #expect(quick.messages.contains { $0.contains("not cleanly unmounted") })
        #expect(quick.messages.contains { $0.contains("read-only") })
        #expect(!VolumeCheck.run(.ext, on: device, options: ["-n"]).passed)
        #expect(!VolumeCheck.run(.ext, on: device, options: []).passed)
        let repair = VolumeCheck.run(.ext, on: device, options: ["-y"])
        #expect(!repair.passed)
        #expect(repair.messages.contains { $0.contains("e2fsck") }, "names the tool that repairs: \(repair.messages)")
        #expect(try device.read(at: 1024 + 0x3A, count: 2) == [0, 0], "a check changes nothing")
    }

    @Test func aVolumeRecordingErrorsFails() throws {
        let device = try Self.copy("ext2")
        try Self.setExtState(0x0003, on: device)
        let report = VolumeCheck.run(.ext, on: device, options: ["-n"])
        #expect(!report.passed)
        #expect(VolumeCheck.run(.ext, on: device, options: ["-q"]).passed)
        #expect(report.messages.contains { $0.contains("errors") })
    }

    @Test func aVolumeThatCannotBeReadFails() throws {
        let device = try Self.copy("ext2")
        // The superblock's magic gone: nothing to open.
        try device.write(at: 1024 + 0x38, [0, 0])
        let report = VolumeCheck.run(.ext, on: device, options: ["-q"])
        #expect(!report.passed)
        #expect(!report.messages.isEmpty)
    }

    @Test func repairIsAskedByYesOrPreenAlsoCombined() {
        #expect(VolumeCheck.repairs(["-y"]) && VolumeCheck.repairs(["-p"]) && VolumeCheck.repairs(["-fy"]))
        #expect(!VolumeCheck.repairs(["-q"]) && !VolumeCheck.repairs(["-n"]) && !VolumeCheck.repairs(["-f", "-n"]))
    }
}
