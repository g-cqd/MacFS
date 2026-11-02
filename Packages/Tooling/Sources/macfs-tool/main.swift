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
    let installer = AnalyzerInstaller(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.download),
        home: NSHomeDirectory()
    )
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
    let result = try plan.execute(with: SystemProcessRunner(timeout: Deadline.planStep), dryRun: dryRun)
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

/// Builds, verifies, installs and registers the Release app (roadmap 0041); with `--check`, runs the mount check after.
func install(_ options: Options) -> Int32 {
    let derivedData = "/tmp/macfs-release"
    let installed = "/Applications/MacFS.app"
    let previous = "/tmp/MacFS.app.previous"
    if options.dryRun {
        print(
            "xcodegen, xcodebuild Release into \(derivedData); verify signatures and entitlements; keep the installed app"
        )
        print(
            "at \(previous); copy to \(installed); unregister and remove the build's copy, register the installed app; stop"
        )
        print("the old module and agent processes; verify the installed signature and the registrations")
        return 0
    }
    print("Building and installing (xcodebuild's output is kept; its last line is shown on failure)...")
    let installer = Installer(
        runner: SystemProcessRunner(capture: true, timeout: Deadline.build),
        root: options.root,
        derivedData: derivedData,
        installed: installed,
        previous: previous,
        team: "NP94WB3P75",
        user: getuid(),
        enabledModules: NSHomeDirectory()
            + "/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist",
        extensions: { app in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: app + "/Contents/Extensions")) ?? []
            return names.filter { $0.hasSuffix(".appex") }.map { String($0.dropLast(".appex".count)) }.sorted()
        }
    )
    let problems = installer.run()
    guard problems.isEmpty else {
        problems.forEach { print("[FAIL] \($0)") }
        return 1
    }
    print("[OK]   installed \(installed) (the previous app is at \(previous))")
    guard options.check else { return 0 }
    // The module processes and FSKit's agent were restarted: a mount 8 s later still found a helper missing ("Couldn't
    // communicate with a helper application", diary 2026-11-01-11).
    Thread.sleep(forTimeInterval: 20)
    return mounts(options)
}

func main() -> Int32 {
    guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
        print(
            "usage: macfs-tool <images|gates|analyzers|plists|mounts|install|summary> [--root DIR] [--dry-run] [--check] [--bench|--corpus] [--mirror HOST]"
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
            case "install":
                return install(options)
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
