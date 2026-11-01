/// Builds the Release app and installs it (roadmap 0041), refusing anything that would install a stale or broken build:
///
/// 1. `xcodegen`, then `xcodebuild` Release; a non-zero exit stops it (a failed build leaves the last one in derived data).
/// 2. The build's signature verified deep and strict; the entitlements each part needs to run (the app and the agent sandboxed,
///    the modules FSKit modules); the agent's Info.plist in its binary (a sandboxed tool traps at launch without one) and its
///    team. Every check reports before it refuses.
/// 3. The installed app kept as `previous`, the build copied in.
/// 4. The installed app registered with its modules, then the build's copy and the previous app unregistered (the build's is
///    registered on build, and its modules ran instead of the installed ones) and the build's removed; the old module and agent
///    processes stopped.
/// 5. The installed signature verified, and every module registered from the installed app.
///
/// `run` returns the problems; none means installed.
public struct Installer: Sendable {
    struct Paths: Sendable {
        let root: String
        let derivedData: String
        let installed: String
        let previous: String

        var built: String { "\(derivedData)/Build/Products/Release/MacFS.app" }
    }

    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    let runner: any ProcessRunning
    let paths: Paths
    let team: String
    /// The user whose FSKit agent is restarted, and FSKit's list of enabled modules (read, never written).
    let user: UInt32
    let enabledModules: String
    let extensions: @Sendable (String) -> [String]

    /// The repository at `root` built into `derivedData`, installed at `installed`, the app it replaces kept at `previous`;
    /// `extensions` lists the module names (without `.appex`) in an app's `Contents/Extensions`.
    public init(
        runner: any ProcessRunning,
        root: String,
        derivedData: String,
        installed: String,
        previous: String,
        team: String,
        user: UInt32,
        enabledModules: String,
        extensions: @escaping @Sendable (String) -> [String]
    ) {
        self.runner = runner
        self.paths = Paths(root: root, derivedData: derivedData, installed: installed, previous: previous)
        self.team = team
        self.user = user
        self.enabledModules = enabledModules
        self.extensions = extensions
    }

    public func run() -> [String] {
        let root = paths.root
        let generated = run(
            "/usr/bin/env",
            ["xcodegen", "generate", "--spec", "\(root)/project.yml", "--project", root]
        )
        guard generated.status == 0 else {
            return ["xcodegen: exit \(generated.status) (\(Self.last(generated.output)))"]
        }
        // swiftly's proxy exports TOOLCHAINS and SDKROOT to `swift package`'s plugins: xcodebuild then builds with the
        // open-source toolchain and the link fails.
        let built = run(
            "/usr/bin/env",
            [
                "-u", "TOOLCHAINS", "-u", "SDKROOT", "/usr/bin/xcodebuild",
                "-project", "\(root)/MacFS.xcodeproj", "-scheme", "MacFS", "-configuration", "Release",
                "-allowProvisioningUpdates", "-derivedDataPath", paths.derivedData, "build"
            ]
        )
        guard built.status == 0 else { return ["build: exit \(built.status) (\(Self.last(built.output)))"] }

        let modules = extensions(paths.built)
        let problems = verify(paths.built, modules)
        guard problems.isEmpty else { return problems }

        _ = run("/bin/rm", ["-rf", paths.previous])
        _ = run("/bin/mv", [paths.installed, paths.previous])  // fails on a first install: nothing to keep
        let copied = run("/usr/bin/ditto", [paths.built, paths.installed])
        guard copied.status == 0 else {
            return ["copy: \(Self.last(copied.output)) (the previous app is at \(paths.previous))"]
        }

        // The installed app registered with its modules (`-R`: `-f` alone registered none, and FSKit then dropped their
        // enablement), before the other copies are unregistered, so the modules are never without a registration. The build's
        // copy and the previous app unregistered (the build's also removed): theirs cannot be the modules that run. Not
        // `pluginkit -r` or `-a`: both lost modules (diary 2026-11-01-07, -09).
        _ = run(Self.lsregister, ["-f", "-R", "-trusted", paths.installed])
        // FSKit's agent restarted on a fresh view of the modules: a stale one listed only some of them, and pruned the others
        // from the enabled list (diary 2026-11-01-11).
        _ = run("/bin/launchctl", ["kickstart", "-k", "user/\(user)/com.apple.fskit.fskit_agent"])
        _ = run(Self.lsregister, ["-u", paths.built])
        _ = run(Self.lsregister, ["-u", paths.previous])
        _ = run("/bin/rm", ["-rf", paths.built])
        _ = run("/usr/bin/pkill", ["-9", "-f", "/Contents/Extensions/[^/]*\\.appex/|/Contents/MacOS/macfs-agent"])

        var installed: [String] = []
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", paths.installed])
        if signature.status != 0 { installed.append("\(paths.installed): signature: \(Self.last(signature.output))") }
        let listing = run("/usr/bin/pluginkit", ["-mAv", "-p", "com.apple.fskit.fsmodule"]).output
        installed += registrations(listing, modules)
        let enabled = run("/usr/bin/plutil", ["-p", enabledModules]).output
        installed += modules.map { "dev.gcqd.MacFS.\($0)" }.filter { !enabled.contains("\"\($0)\"") }
            .map {
                "\($0) is not enabled in FSKit: enable it in System Settings › General › Login Items & Extensions › File System Extensions"
            }
        return installed
    }

    /// The build's signature, each part's entitlements, and the agent's Info.plist and team.
    func verify(_ app: String, _ modules: [String]) -> [String] {
        var problems: [String] = []
        let signature = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app])
        if signature.status != 0 { problems.append("\(app): signature: \(Self.last(signature.output))") }
        let agent = "\(app)/Contents/MacOS/macfs-agent"
        let parts =
            [(app, ["com.apple.security.app-sandbox", "com.apple.security.application-groups"])]
            + modules.map {
                (
                    "\(app)/Contents/Extensions/\($0).appex",
                    ["com.apple.developer.fskit.fsmodule", "com.apple.security.app-sandbox"]
                )
            }
            + [(agent, ["com.apple.security.app-sandbox", "com.apple.security.application-groups"])]
        for (path, keys) in parts {
            let entitlements = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", path]).output
            for key in keys where !entitlements.contains("<key>\(key)</key>") {
                problems.append("\(path): no \(key) entitlement")
            }
        }
        let details = run("/usr/bin/codesign", ["-dv", agent]).output
        if !details.contains("Info.plist entries=") {
            problems.append("\(agent): no Info.plist in the binary (a sandboxed tool traps at launch)")
        }
        if let signer = Self.value("TeamIdentifier=", in: details), signer != team {
            problems.append("\(agent): signed by team \(signer), not \(team)")
        }
        return problems
    }

    /// Each module registered once, from the installed app (pluginkit's `-mAv` lines: id(version), uuid, date, path).
    func registrations(_ listing: String, _ modules: [String]) -> [String] {
        var problems: [String] = []
        let lines = listing.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
        for module in modules {
            let id = "dev.gcqd.MacFS.\(module)"
            let paths = lines.filter { ($0.first ?? "").contains("\(id)(") }.compactMap(\.last)
            if paths.isEmpty { problems.append("\(id) is not registered") }
            for path in paths where !path.hasPrefix("\(self.paths.installed)/") {
                problems.append("\(id) is registered at \(path), not in \(self.paths.installed)")
            }
        }
        return problems
    }

    private func run(_ executable: String, _ arguments: [String]) -> ProcessResult {
        (try? runner.run(Command(executable, arguments)))
            ?? ProcessResult(status: -1, output: "\(executable) did not run")
    }

    /// The last non-empty line of a tool's output: where xcodebuild and codesign say what went wrong.
    static func last(_ output: String) -> String {
        output.split(separator: "\n").last { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
    }

    static func value(_ prefix: String, in output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
