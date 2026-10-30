import FSCore
import MountKit
import Testing

@Suite struct ProbeAnswerTests {
    static let volume = VolumeDescription(
        format: "ext4", label: "data", uuid: [1], caseRule: .sensitive, maximumNameLength: 255)

    /// Disk Arbitration mounts only a `usable` answer: `usableButLimited` is logged as "unable to probe
    /// (status code 0xFFFFFFFA)" and the disk stays unmounted (diary 2026-10-30-04).
    @Test func aVolumeTheReaderOpensIsUsableSoDiskArbitrationMountsIt() {
        #expect(ProbeAnswer(Self.volume) == .usable(name: "data"))
    }

    @Test func noVolumeIsNotRecognized() {
        #expect(ProbeAnswer(nil) == .notRecognized)
    }

    @Test func anUnlabelledVolumeIsNamedByItsFormat() {
        var volume = Self.volume
        volume.label = ""
        #expect(ProbeAnswer(volume) == .usable(name: "ext4"))
    }
}
