import Formats
import Foundation
import ToolingCore

// macfs-tool <images|gates|analyzers|plists|mounts|summary> [--root DIR] [--dry-run] [--check] [--bench|--corpus]
// The command plugins call this; it can also be run directly with `swift run macfs-tool`.

struct Options {
    var command = ""
    var root = FileManager.default.currentDirectoryPath
    var dryRun = false
    var check = false
    var kind = TestImages.Kind.test
    var mirror: String?
}

func parse(_ arguments: [String]) -> Options? {
    var options = Options()
    var rest = arguments.makeIterator()
    guard let command = rest.next() else { return nil }
    options.command = command
    while let argument = rest.next() {
        switch argument {
            case "--root": options.root = rest.next() ?? options.root
            case "--dry-run": options.dryRun = true
            case "--check": options.check = true
            case "--bench": options.kind = .bench
            case "--corpus": options.kind = .corpus
            case "--mirror": options.mirror = rest.next()
            default: return nil
        }
    }
    return options
}

/// The family's analyzers lock, copied from aemi (roadmap 0010).
func analyzerLock(_ root: String) throws -> AnalyzerLock {
    try AnalyzerLock(contentsOf: root + "/Scripts/analyzers.lock")
}

/// Installs every locked analyzer that is missing or of another version; prints what it did.
func installAnalyzers(_ root: String, dryRun: Bool) throws -> Int32 {
    let installer = AnalyzerInstaller(runner: SystemProcessRunner(capture: true), home: NSHomeDirectory())
    for pin in try analyzerLock(root).pins {
        if dryRun {
            print("\(pin.tool) \(pin.version): \(pin.url) (sha256 \(pin.macOS))")
            continue
        }
        let outcome = try installer.install(pin)
        print("[\(outcome == .installed ? "INSTALLED" : "OK")] \(pin.tool) \(pin.version)")
    }
    return 0
}

func locator(_ root: String? = nil) -> ToolLocator {
    let lock = root.flatMap { try? analyzerLock($0) }
    return ToolLocator(environment: ProcessInfo.processInfo.environment, home: NSHomeDirectory(), lock: lock) { path in
        path.hasSuffix(".jar")
            ? FileManager.default.isReadableFile(atPath: path) : FileManager.default.isExecutableFile(atPath: path)
    }
}

func report(_ plan: Plan, dryRun: Bool) throws -> Int32 {
    let result = try plan.execute(with: SystemProcessRunner(), dryRun: dryRun)
    if dryRun { result.lines.forEach { print($0) } }
    for failure in result.failed { print("[FAIL] \(failure.display)") }
    return result.succeeded ? 0 : 1
}

func plists(_ options: Options) throws -> Int32 {
    var drifted = false
    for format in DiskFormat.allCases {
        let url = URL(fileURLWithPath: options.root).appendingPathComponent(ModulePlist.directory(for: format))
            .appendingPathComponent("Info.plist")
        guard ModulePlist.drifted(existing: try? Data(contentsOf: url), for: format) else { continue }
        drifted = true
        if options.check || options.dryRun {
            print("[DRIFT] \(url.path) differs from DiskFormat.\(format)")
        } else {
            try ModulePlist.data(for: format).write(to: url)
            print("wrote \(url.path)")
        }
    }
    return options.check && drifted ? 1 : 0
}

/// Every test image through its FSKit module (roadmap 0025). Needs the app in /Applications with its modules enabled.
func mounts(_ options: Options) -> Int32 {
    if options.dryRun {
        for target in MountCheck.targets {
            print(
                "TestImages/\(target.image).img: attach, mount -F -t \(target.type), compare, refuse a write, release"
            )
            print(
                "TestImages/\(target.image).img: clone, mount through MacFS's agent, compare, refuse a write, unmount"
            )
        }
        return 0
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("macfs-mounts-\(getpid())").path
    let check = MountCheck(
        runner: SystemProcessRunner(capture: true),
        root: options.root,
        mountPoint: { target in
            let point = base + "/" + target.image
            try? FileManager.default.createDirectory(atPath: point, withIntermediateDirectories: true)
            return point
        },
        verification: .manifest
    )
    // The agent path (roadmap 0039): the installed app mounts a clone in its container through its agent.
    let container = NSHomeDirectory() + "/Library/Containers/dev.gcqd.MacFS/Data/tmp"
    let app = AppLaunch(
        runner: SystemProcessRunner(capture: true),
        app: "/Applications/MacFS.app",
        resultFile: container + "/agentcheck-result.txt"
    )
    let agent = AgentMountCheck(
        runner: SystemProcessRunner(capture: true),
        root: options.root,
        container: container,
        launch: app.run,
        verification: .manifest
    )
    var failed = false
    func report(_ outcome: MountCheck.Outcome, _ path: String) {
        let target = outcome.target
        if outcome.problems.isEmpty {
            print("[OK]   \(target.image) (\(target.type), \(path))")
        } else {
            failed = true
            print("[FAIL] \(target.image) (\(target.type), \(path))")
            outcome.problems.prefix(10).forEach { print("       \($0)") }
        }
    }
    for target in MountCheck.targets { report(check.run(target), "FSKit") }
    try? FileManager.default.createDirectory(atPath: container, withIntermediateDirectories: true)
    for target in MountCheck.targets { report(agent.run(target), "agent") }
    try? FileManager.default.removeItem(atPath: base)
    return failed ? 1 : 0
}

func main() -> Int32 {
    guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
        print(
            "usage: macfs-tool <images|gates|analyzers|plists|mounts|summary> [--root DIR] [--dry-run] [--check] [--bench|--corpus] [--mirror HOST]"
        )
        return 64
    }
    do {
        switch options.command {
            case "images":
                guard let container = locator().find("container") ?? locator().find("docker") else {
                    print("[FAIL] neither Apple's container nor docker is installed")
                    return 2
                }
                try FileManager.default.createDirectory(
                    atPath: options.root + "/" + options.kind.directory,
                    withIntermediateDirectories: true
                )
                return try report(
                    TestImages.plan(
                        root: options.root,
                        container: container,
                        kind: options.kind,
                        mirror: options.mirror
                    ),
                    dryRun: options.dryRun
                )
            case "gates":
                if !options.dryRun { _ = try installAnalyzers(options.root, dryRun: false) }
                return try report(
                    Gates.plan(root: options.root, tools: try locator(options.root).gatePaths()),
                    dryRun: options.dryRun
                )
            case "analyzers":
                return try installAnalyzers(options.root, dryRun: options.dryRun)
            case "plists":
                return try plists(options)
            case "mounts":
                return mounts(options)
            case "summary":
                let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                TestSummary.reduce(input).forEach { print($0) }
                return 0
            default:
                print("unknown command \(options.command)")
                return 64
        }
    } catch let missing as ToolLocator.Missing {
        print("[FAIL] missing tools: \(missing.tools.joined(separator: ", ")) (set MACFS_<NAME> to a binary)")
        return 2
    } catch {
        print("[FAIL] \(error)")
        return 1
    }
}

exit(main())
