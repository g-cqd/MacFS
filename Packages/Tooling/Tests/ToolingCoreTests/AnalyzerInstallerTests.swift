import CryptoKit
import Foundation
import Synchronization
import Testing
import ToolingCore

/// Installing a locked analyzer (roadmap 0010), as aemi's `analyzers.sh` does: download the release archive, refuse it unless its
/// SHA-256 is the lock's, unpack it into the shared cache, refuse the binary unless `--version` says the locked version. The runner
/// plays curl, tar and the tool; files are real, in a temporary home.
@Suite struct AnalyzerInstallerTests {
    let home: String
    let archive = Data("pretend archive".utf8)
    var digest: String { SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined() }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("analyzers-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    func pin(hash: String? = nil) -> AnalyzerLock.Pin {
        AnalyzerLock.Pin(
            tool: "fcheck",
            version: "0.4.0",
            macOS: hash ?? digest,
            linux: String(repeating: "0", count: 64)
        )
    }

    /// curl writes `archive`, tar unpacks `fcheck-0.4.0-macos-arm64/fcheck`, and the tool reports `reported`.
    func runner(download: Int32 = 0, reported: String = "0.4.0") -> RecordingRunner {
        let archive = archive
        return RecordingRunner { command in
            let arguments = command.arguments
            if command.executable == "/usr/bin/curl", let index = arguments.firstIndex(of: "-o") {
                if download == 0 { FileManager.default.createFile(atPath: arguments[index + 1], contents: archive) }
                return ProcessResult(status: download, output: "")
            }
            if command.executable == "/usr/bin/tar", let index = arguments.firstIndex(of: "-C") {
                let directory = arguments[index + 1] + "/fcheck-0.4.0-macos-arm64"
                try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                FileManager.default.createFile(
                    atPath: directory + "/fcheck",
                    contents: Data("#!".utf8),
                    attributes: [.posixPermissions: 0o755]
                )
                return ProcessResult(status: 0, output: "")
            }
            if arguments == ["--version"] { return ProcessResult(status: 0, output: reported + "\n") }
            return ProcessResult(status: 99, output: "unexpected \(command.display)")
        }
    }

    var installed: String { ToolLocator.installDirectory(pin(), home: home) + "/fcheck" }

    @Test func aLockedReleaseIsDownloadedCheckedAndInstalled() throws {
        let runner = runner()
        let outcome = try AnalyzerInstaller(runner: runner, home: home).install(pin())
        #expect(outcome == .installed)
        #expect(FileManager.default.isExecutableFile(atPath: installed))
        let curl = try #require(runner.commands.withLock { $0.first })
        #expect(curl.arguments.contains(pin().url))
    }

    @Test func anInstalledToolOfTheLockedVersionIsLeftAlone() throws {
        _ = try AnalyzerInstaller(runner: runner(), home: home).install(pin())
        let again = runner()
        #expect(try AnalyzerInstaller(runner: again, home: home).install(pin()) == .present)
        #expect(!again.executables.contains("/usr/bin/curl"))
    }

    @Test func anArchiveOfAnotherHashIsRefusedAndNothingIsInstalled() {
        let other = String(repeating: "e", count: 64)
        #expect(throws: AnalyzerInstaller.Failure.hash(tool: "fcheck", actual: digest, pinned: other)) {
            try AnalyzerInstaller(runner: runner(), home: home).install(pin(hash: other))
        }
        #expect(!FileManager.default.fileExists(atPath: installed))
    }

    @Test func aFailedDownloadIsReported() {
        #expect(throws: AnalyzerInstaller.Failure.download(tool: "fcheck", status: 22)) {
            try AnalyzerInstaller(runner: runner(download: 22), home: home).install(pin())
        }
    }

    @Test func aBinaryOfAnotherVersionIsRemoved() {
        #expect(throws: AnalyzerInstaller.Failure.version(tool: "fcheck", reported: "0.3.9", pinned: "0.4.0")) {
            try AnalyzerInstaller(runner: runner(reported: "0.3.9"), home: home).install(pin())
        }
        #expect(!FileManager.default.fileExists(atPath: installed))
    }

    /// An installed binary that now reports another version (a partial copy, a hand edit) is installed again.
    @Test func anInstalledToolOfAnotherVersionIsReplaced() throws {
        _ = try AnalyzerInstaller(runner: runner(), home: home).install(pin())
        let stale = RecordingRunner {
            $0.arguments == ["--version"]
                ? ProcessResult(status: 0, output: "0.3.0") : ProcessResult(status: 1, output: "")
        }
        #expect(throws: AnalyzerInstaller.Failure.self) {
            try AnalyzerInstaller(runner: stale, home: home).install(pin())
        }
        #expect(stale.executables.contains("/usr/bin/curl"))
    }
}
