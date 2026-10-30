import FSCore
import Testing

@testable import ExtFS

/// Every node of every ext image against the Linux kernel's own view of it (docs/conformance/ext.md).
@Suite struct ExtConformanceTests {
    @Test(arguments: ExtImageTests.images)
    func everyNodeMatchesTheLinuxKernel(_ name: String) throws {
        let fileSystem = try ExtFileSystem(source: try ImageOracle.image(name))
        for problem in try ReferenceOracle.compare(fileSystem, reference: name) { Issue.record("\(name): \(problem)") }
    }
}
