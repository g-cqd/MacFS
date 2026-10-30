import FSCore
import Testing

@testable import NTFS

/// Every node of the NTFS image against ntfs-3g's view of it (docs/conformance/ntfs.md).
@Suite struct NTFSConformanceTests {
    @Test func everyNodeMatchesNTFS3G() throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image("ntfs"))
        for problem in try ReferenceOracle.compare(fileSystem, reference: "ntfs") { Issue.record("ntfs: \(problem)") }
    }
}
