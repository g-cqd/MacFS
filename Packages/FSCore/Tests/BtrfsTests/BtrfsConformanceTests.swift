import FSCore
import Testing

@testable import Btrfs

/// Every node of every Btrfs image against btrfs-progs' own reader (`btrfs restore -m -S -x`; docs/conformance/btrfs.md).
@Suite struct BtrfsConformanceTests {
    @Test(arguments: BtrfsImageTests.images)
    func everyNodeMatchesBtrfsProgs(_ name: String) throws {
        let fileSystem = try BtrfsFileSystem(source: try ImageOracle.image(name))
        for problem in try ReferenceOracle.compare(fileSystem, reference: name) { Issue.record("\(name): \(problem)") }
    }
}
