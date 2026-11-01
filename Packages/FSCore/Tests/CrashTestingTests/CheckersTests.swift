import CrashTesting
import Foundation
import Testing

/// Each format's own checker, in the container (ADR-0018 decision 5): one run for a batch of images, a status and the output
/// for each.
@Suite(.enabled(if: Checkers.isAvailable)) struct CheckersTests {
    static let ext2 = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../TestImages/ext2.img").standardizedFileURL.path

    @Test func aCleanVolumePassesAndADamagedOneDoesNot() throws {
        let clean = try [UInt8](Data(contentsOf: URL(fileURLWithPath: Self.ext2)))
        var damaged = clean
        // s_inodes_count zeroed: the superblock is corrupt.
        damaged.replaceSubrange(1024 ..< 1028, with: [0, 0, 0, 0])
        let results = try #require(Checkers.run(["e2fsck", "-fn"], on: ["clean": clean, "damaged": damaged]))
        #expect(results["clean"]?.status == 0, "\(results["clean"]?.output ?? "")")
        #expect(results["damaged"]?.status != 0)
    }

    /// Several commands on each image, in order, in one run: a repair, then a check of what it left.
    @Test func commandsRunInOrderOnEachImage() throws {
        var dirty = try [UInt8](Data(contentsOf: URL(fileURLWithPath: Self.ext2)))
        // The free blocks count off by one: what e2fsck's preen fixes without asking.
        dirty[1024 + 0x0C] &+= 1
        let results = try #require(Checkers.run([["e2fsck", "-fp"], ["e2fsck", "-fn"]], on: ["dirty": dirty]))
        let steps = try #require(results["dirty"])
        #expect(steps.count == 2)
        #expect(steps[0].status <= 1, "\(steps[0].output)")
        #expect(steps[1].status == 0, "\(steps[1].output)")
    }
}
