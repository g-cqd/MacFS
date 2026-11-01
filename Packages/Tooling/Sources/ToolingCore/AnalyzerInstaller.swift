import CryptoKit
import Foundation

/// Installs a locked analyzer where `ToolLocator` and aemi's `analyzers.sh` look for it (roadmap 0010): the release archive,
/// refused unless its SHA-256 is the lock's, unpacked into the shared cache, refused unless the binary reports the locked
/// version. Baseline fingerprints move between versions, so an unpinned analyzer could turn a gate red with no change here.
public struct AnalyzerInstaller: Sendable {
    public enum Outcome: Equatable, Sendable { case present, installed }

    public enum Failure: Error, Equatable {
        case download(tool: String, status: Int32)
        case hash(tool: String, actual: String, pinned: String)
        case unpack(tool: String, status: Int32)
        case version(tool: String, reported: String, pinned: String)
    }

    private let runner: any ProcessRunning
    private let home: String

    public init(runner: any ProcessRunning, home: String) {
        self.runner = runner
        self.home = home
    }

    public func install(_ pin: AnalyzerLock.Pin) throws -> Outcome {
        let files = FileManager.default
        let directory = ToolLocator.installDirectory(pin, home: home)
        let binary = "\(directory)/\(pin.tool)"
        if files.isExecutableFile(atPath: binary), try reported(binary) == pin.version { return .present }
        let scratch = files.temporaryDirectory.appendingPathComponent("analyzer-\(UUID().uuidString)").path
        try files.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(atPath: scratch) }
        let archive = "\(scratch)/\(pin.archive).tar.gz"
        let download = try runner.run(Command("/usr/bin/curl", ["-fsSL", "--retry", "3", "-o", archive, pin.url]))
        guard download.status == 0 else { throw Failure.download(tool: pin.tool, status: download.status) }
        let actual = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: archive)))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == pin.macOS else { throw Failure.hash(tool: pin.tool, actual: actual, pinned: pin.macOS) }
        let unpack = try runner.run(Command("/usr/bin/tar", ["-xzf", archive, "-C", scratch]))
        guard unpack.status == 0 else { throw Failure.unpack(tool: pin.tool, status: unpack.status) }
        // The whole directory: an archive may carry libraries beside the binary.
        try? files.removeItem(atPath: directory)
        try files.createDirectory(
            atPath: (directory as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try files.copyItem(atPath: "\(scratch)/\(pin.archive)", toPath: directory)
        let version = try reported(binary)
        guard version == pin.version else {
            try? files.removeItem(atPath: directory)
            throw Failure.version(tool: pin.tool, reported: version, pinned: pin.version)
        }
        return .installed
    }

    private func reported(_ binary: String) throws -> String {
        try runner.run(Command(binary, ["--version"])).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
