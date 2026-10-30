import FSCore
import Testing

@testable import NTFS

/// Every node of the NTFS image against ntfs-3g's view of it (docs/conformance/ntfs.md).
@Suite struct NTFSConformanceTests {
    @Test(arguments: NTFSImageTests.images)
    func everyNodeMatchesNTFS3G(_ name: String) throws {
        let fileSystem = try NTFSFileSystem(source: try ImageOracle.image(name))
        for problem in try ReferenceOracle.compare(fileSystem, reference: name) { Issue.record("\(name): \(problem)") }
    }
}
