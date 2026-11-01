import DiskKit
import Testing

/// The disks the app shows, kept by the watcher's events: whole disks in order, each with its partitions.
struct DiskListTests {
    static func disk(_ key: String) -> DiskDescription { DiskDescription(Recorded[key])! }

    @Test func eventsAddChangeAndRemoveDisks() {
        var list = DiskList()
        list.apply(.appeared(Self.disk("ext4-gpt nomount disk9")))
        list.apply(.appeared(Self.disk("ext4-gpt nomount disk9s1")))
        list.apply(.appeared(Self.disk("apfs nomount disk10")))
        #expect(list.wholeDisks.map(\.id) == ["disk9", "disk10"])
        #expect(list.partitions(of: "disk9").map(\.id) == ["disk9s1"])
        list.apply(.changed(Self.disk("ext4-gpt mounted disk9s1")))
        #expect(list.partitions(of: "disk9").first?.volume?.path == "/Volumes/ext4-gpt")
        list.apply(.disappeared("disk9s1"))
        list.apply(.disappeared("disk9"))
        #expect(list.wholeDisks.map(\.id) == ["disk10"])
        #expect(list.partitions(of: "disk9").isEmpty)
    }

    /// Ordered as a person reads them: disk2 before disk10, disk9s2 before disk9s10.
    @Test func disksAreInNumericOrder() {
        var list = DiskList()
        for id in ["disk10", "disk2", "disk9"] {
            var values = Recorded["ext4 mounted disk9"]
            values["DAMediaBSDName"] = .text(id)
            list.apply(.appeared(DiskDescription(values)!))
        }
        for id in ["disk9s10", "disk9s2"] {
            var values = Recorded["ext4-gpt nomount disk9s1"]
            values["DAMediaBSDName"] = .text(id)
            list.apply(.appeared(DiskDescription(values)!))
        }
        #expect(list.wholeDisks.map(\.id) == ["disk2", "disk9", "disk10"])
        #expect(list.partitions(of: "disk9").map(\.id) == ["disk9s2", "disk9s10"])
    }
}
