import Testing
import ToolingCore

/// The family's analyzers lock (aemi `Scripts/analyzers.lock`, copied to `Scripts/analyzers.lock`): tool, version, SHA-256 of
/// the macOS arm64 archive, SHA-256 of the Linux x86_64 one (roadmap 0010).
@Suite struct AnalyzerLockTests {
    static let text = """
        # comment
        arcleak 0.15.0 \(String(repeating: "a", count: 64)) \(String(repeating: "b", count: 64))

        fcheck 0.4.0 \(String(repeating: "c", count: 64)) \(String(repeating: "d", count: 64))
        """

    @Test func itReadsEachToolsVersionAndHashes() throws {
        let lock = try AnalyzerLock(Self.text)
        #expect(lock.pins.map(\.tool) == ["arcleak", "fcheck"])
        #expect(
            lock["fcheck"]
                == AnalyzerLock.Pin(
                    tool: "fcheck",
                    version: "0.4.0",
                    macOS: String(repeating: "c", count: 64),
                    linux: String(repeating: "d", count: 64)
                )
        )
        #expect(lock["dolly"] == nil)
    }

    @Test(arguments: [
        "dolly 0.13.0 abc def", "dolly 0.13.0",
        "dolly 0.13.0 \(String(repeating: "g", count: 64)) \(String(repeating: "a", count: 64))"
    ])
    func aMalformedLineIsRefused(_ line: String) {
        #expect(throws: AnalyzerLock.Malformed.self) { try AnalyzerLock(line) }
    }

    @Test func theArchiveComesFromTheToolsRelease() throws {
        let pin = try #require(try AnalyzerLock(Self.text)["arcleak"])
        #expect(pin.archive == "arcleak-0.15.0-macos-arm64")
        #expect(
            pin.url == "https://github.com/g-cqd/arcleak/releases/download/v0.15.0/arcleak-0.15.0-macos-arm64.tar.gz"
        )
    }

    /// Where aemi's `analyzers.sh` installs, so every package of the family shares one download.
    @Test func theLockedToolsAreFoundInTheSharedCache() throws {
        let lock = try AnalyzerLock(Self.text)
        let cached = "/h/Library/Caches/g-cqd-analyzers/fcheck-0.4.0/fcheck"
        let locator = ToolLocator(environment: ["PATH": "/bin"], home: "/h", lock: lock, isExecutable: { $0 == cached })
        #expect(locator.find("fcheck", pinned: locator.pinnedLocations("fcheck")) == cached)
        #expect(locator.pinnedLocations("arcleak") == ["/h/Library/Caches/g-cqd-analyzers/arcleak-0.15.0/arcleak"])
    }

    /// The repository's lock is the family's: every analyzer the gates run is pinned.
    @Test func theRepositoryLockPinsEveryGateAnalyzer() throws {
        let lock = try AnalyzerLock(contentsOf: Self.repository + "/Scripts/analyzers.lock")
        for tool in ["deadwood", "dolly", "arcleak", "fcheck", "modeler"] { #expect(lock[tool] != nil, "\(tool)") }
    }

    static let repository: String = {
        var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
        parts.removeLast(5)  // Tests/ToolingCoreTests/AnalyzerLockTests.swift, Tooling, Packages
        return parts.joined(separator: "/")
    }()
}
