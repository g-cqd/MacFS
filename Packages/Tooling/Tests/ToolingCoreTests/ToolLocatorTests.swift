import Testing
import ToolingCore

@Suite struct ToolLocatorTests {
    @Test func anEnvironmentOverrideWinsThenPinnedPathsThenThePath() {
        let present: Set<String> = ["/env/dolly", "/cache/dolly-0.11.0/dolly", "/usr/bin/dolly", "/opt/bin/swiftlint"]
        let locator = ToolLocator(
            environment: ["MACFS_DOLLY": "/env/dolly", "PATH": "/usr/bin:/opt/bin"], home: "/home",
            isExecutable: { present.contains($0) })
        #expect(locator.find("dolly", pinned: ["/cache/dolly-0.11.0/dolly"]) == "/env/dolly")
        let noOverride = ToolLocator(
            environment: ["PATH": "/usr/bin:/opt/bin"], home: "/home", isExecutable: { present.contains($0) })
        #expect(noOverride.find("dolly", pinned: ["/cache/dolly-0.11.0/dolly"]) == "/cache/dolly-0.11.0/dolly")
        #expect(noOverride.find("swiftlint") == "/opt/bin/swiftlint")
        #expect(noOverride.find("absent") == nil)
    }

    @Test func anOverrideThatIsNotExecutableIsNotUsed() {
        let locator = ToolLocator(
            environment: ["MACFS_DOLLY": "/missing", "PATH": "/usr/bin"], home: "/h",
            isExecutable: { $0 == "/usr/bin/dolly" })
        #expect(locator.find("dolly") == "/usr/bin/dolly")
    }

    @Test func gatePathsNameEveryMissingTool() {
        let locator = ToolLocator(environment: ["PATH": "/bin"], home: "/h", isExecutable: { $0 == "/bin/swift" })
        #expect(
            throws: ToolLocator.Missing(tools: [
                "swiftlint", "deadwood", "dolly", "arcleak", "fcheck", "modeler", "java", "tla2tools.jar", "lake"
            ])
        ) {
            try locator.gatePaths()
        }
    }
}
