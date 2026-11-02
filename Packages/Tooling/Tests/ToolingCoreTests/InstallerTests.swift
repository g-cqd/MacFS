import Darwin
import Synchronization
import Testing
import ToolingCore

/// The install (roadmap 0041), on the recording runner: nothing is built, copied or registered. The fake answers as the real
/// tools did on a good build (codesign's entitlements as XML, its `-dv` lines; pluginkit's listing).
@Suite struct InstallerTests {
    static let built = "/dd/Build/Products/Release/MacFS.app"
    static let modules = ["BtrfsFS", "ExtFSModule"]

    /// What the tools answer for a good build; `change` alters one answer.
    static func answers(_ change: @escaping @Sendable (Command) -> ProcessResult? = { _ in nil }) -> RecordingRunner {
        RecordingRunner { command in
            if let changed = change(command) { return changed }
            let arguments = command.arguments
            switch command.executable {
                case "/usr/bin/codesign" where arguments.contains("--entitlements"):
                    let path = arguments.last ?? ""
                    let keys =
                        path.hasSuffix(".appex")
                        ? ["com.apple.developer.fskit.fsmodule", "com.apple.security.app-sandbox"]
                        : ["com.apple.security.app-sandbox", "com.apple.security.application-groups"]
                    return ProcessResult(status: 0, output: keys.map { "<key>\($0)</key><true/>" }.joined())
                case "/usr/bin/codesign" where arguments.first == "-dv":
                    return ProcessResult(
                        status: 0,
                        output: "Identifier=x\nInfo.plist entries=18\nTeamIdentifier=NP94WB3P75\n"
                    )
                case "/usr/bin/pluginkit" where arguments.first == "-mAv":
                    let lines = modules.map {
                        "     dev.gcqd.MacFS.\($0)(0.1)\tUUID\tdate\t/Applications/MacFS.app/Contents/Extensions/\($0).appex"
                    }
                    return ProcessResult(status: 0, output: lines.joined(separator: "\n"))
                case "/usr/bin/plutil" where arguments.last == Self.enabledModules:
                    let lines = modules.enumerated().map { "  \($0.offset) => \"dev.gcqd.MacFS.\($0.element)\"" }
                    return ProcessResult(status: 0, output: "[\n" + lines.joined(separator: "\n") + "\n]")
                default:
                    return ProcessResult(status: 0, output: "")
            }
        }
    }

    static let enabledModules = "/Users/u/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"

    func install(_ runner: RecordingRunner) -> [String] {
        Installer(
            runner: runner,
            root: "/repo",
            derivedData: "/dd",
            installed: "/Applications/MacFS.app",
            previous: "/tmp/MacFS.app.previous",
            team: "NP94WB3P75",
            user: 503,
            enabledModules: Self.enabledModules,
            extensions: { _ in Self.modules }
        )
        .run()
    }

    @Test func aGoodBuildIsVerifiedInstalledAndRegisteredInOrder() {
        let runner = Self.answers()
        #expect(install(runner).isEmpty)
        let commands = runner.commands.withLock { $0 }
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let expected: [Command] = [
            Command("/usr/bin/env", ["xcodegen", "generate", "--spec", "/repo/project.yml", "--project", "/repo"]),
            // swiftly's proxy exports TOOLCHAINS and SDKROOT to the plugin: xcodebuild then builds with the open-source
            // toolchain and the link fails. The build runs without them.
            Command(
                "/usr/bin/env",
                [
                    "-u", "TOOLCHAINS", "-u", "SDKROOT", "/usr/bin/xcodebuild",
                    "-project", "/repo/MacFS.xcodeproj", "-scheme", "MacFS", "-configuration", "Release",
                    "-allowProvisioningUpdates", "-derivedDataPath", "/dd", "build"
                ]
            ),
            Command("/usr/bin/codesign", ["--verify", "--deep", "--strict", Self.built]),
            Command("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", Self.built]),
            Command(
                "/usr/bin/codesign",
                ["-d", "--entitlements", "-", "--xml", "\(Self.built)/Contents/Extensions/BtrfsFS.appex"]
            ),
            Command(
                "/usr/bin/codesign",
                ["-d", "--entitlements", "-", "--xml", "\(Self.built)/Contents/Extensions/ExtFSModule.appex"]
            ),
            Command(
                "/usr/bin/codesign",
                ["-d", "--entitlements", "-", "--xml", "\(Self.built)/Contents/MacOS/macfs-agent"]
            ),
            Command("/usr/bin/codesign", ["-dv", "\(Self.built)/Contents/MacOS/macfs-agent"]),
            Command("/bin/rm", ["-rf", "/tmp/MacFS.app.previous"]),
            Command("/bin/mv", ["/Applications/MacFS.app", "/tmp/MacFS.app.previous"]),
            Command("/usr/bin/ditto", [Self.built, "/Applications/MacFS.app"]),
            // The installed app registered with its modules (`-R`: `-f` alone registered none, and FSKit then dropped their
            // enablement), before the other copies are unregistered: the modules are never without a registration. The build's
            // copy and the previous app unregistered (the build's also removed), so theirs cannot be the modules that run. No
            // `pluginkit -r`/`-a`: both lost modules (diary 2026-11-01-07, -09).
            Command(lsregister, ["-f", "-R", "-trusted", "/Applications/MacFS.app"]),
            // FSKit's agent restarted on a fresh view of the modules: a stale one listed only some of them, and pruned the others
            // from the enabled list (diary 2026-11-01-11).
            Command("/bin/launchctl", ["kickstart", "-k", "user/503/com.apple.fskit.fskit_agent"]),
            Command(lsregister, ["-u", Self.built]),
            Command(lsregister, ["-u", "/tmp/MacFS.app.previous"]),
            Command("/bin/rm", ["-rf", Self.built]),
            Command("/usr/bin/pkill", ["-9", "-f", Installer.staleProcesses]),
            Command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "/Applications/MacFS.app"]),
            Command("/usr/bin/pluginkit", ["-mAv", "-p", "com.apple.fskit.fsmodule"]),
            Command("/usr/bin/plutil", ["-p", Self.enabledModules])
        ]
        #expect(commands == expected)
    }

    /// FSKit dropping a module from its enabled list is a failure the installer names: only System Settings gives it back, and a
    /// mount check would otherwise report it as a mount that does not work.
    @Test func aModuleFSKitNoLongerEnablesIsReported() {
        let runner = Self.answers { command in
            command.executable == "/usr/bin/plutil"
                // A longer identifier that contains the module's is not the module's.
                ? ProcessResult(
                    status: 0,
                    output: "[\n  0 => \"dev.gcqd.MacFS.ExtFSModule\"\n  1 => \"dev.gcqd.MacFS.BtrfsFS.old\"\n]"
                ) : nil
        }
        #expect(
            install(runner) == [
                "dev.gcqd.MacFS.BtrfsFS is not enabled in FSKit: enable it in System Settings › General › Login Items & Extensions › File System Extensions"
            ]
        )
    }

    /// A failed build leaves the last one in derived data, ready to be installed by mistake (AGENTS.md): nothing after it runs.
    @Test func aFailedBuildStopsBeforeAnythingIsVerifiedOrCopied() {
        let runner = Self.answers {
            $0.arguments.contains("/usr/bin/xcodebuild")
                ? ProcessResult(status: 65, output: "x\n** BUILD FAILED **") : nil
        }
        #expect(install(runner) == ["build: exit 65 (** BUILD FAILED **)"])
        #expect(runner.commands.withLock { $0 }.last?.arguments.contains("/usr/bin/xcodebuild") == true)
    }

    @Test func aGenerateThatFailsStopsThere() {
        let runner = Self.answers {
            $0.arguments.first == "xcodegen" ? ProcessResult(status: 1, output: "bad spec") : nil
        }
        #expect(install(runner) == ["xcodegen: exit 1 (bad spec)"])
        #expect(runner.executables == ["/usr/bin/env"])
    }

    /// Every check of the build runs and reports before refusing, and the installed app is left alone.
    @Test func aBuildMissingAnEntitlementOrItsInfoPlistIsRefusedWhole() {
        let runner = Self.answers { command in
            if command.arguments.last?.hasSuffix("BtrfsFS.appex") == true, command.arguments.contains("--entitlements")
            {
                return ProcessResult(status: 0, output: "<key>com.apple.security.app-sandbox</key><true/>")
            }
            if command.arguments.first == "-dv" {
                return ProcessResult(
                    status: 0,
                    output: "Identifier=x\nInfo.plist=not bound\nTeamIdentifier=NP94WB3P75\n"
                )
            }
            return nil
        }
        #expect(
            install(runner) == [
                "\(Self.built)/Contents/Extensions/BtrfsFS.appex: no com.apple.developer.fskit.fsmodule entitlement",
                "\(Self.built)/Contents/MacOS/macfs-agent: no Info.plist in the binary (a sandboxed tool traps at launch)"
            ]
        )
        #expect(!runner.executables.contains("/usr/bin/ditto") && !runner.executables.contains("/bin/mv"))
    }

    @Test func anotherTeamsSignatureIsRefused() {
        let runner = Self.answers {
            $0.arguments.first == "-dv"
                ? ProcessResult(status: 0, output: "Info.plist entries=18\nTeamIdentifier=ZZZ\n") : nil
        }
        #expect(install(runner) == ["\(Self.built)/Contents/MacOS/macfs-agent: signed by team ZZZ, not NP94WB3P75"])
    }

    @Test func aSignatureThatDoesNotVerifyIsRefused() {
        let runner = Self.answers {
            $0.arguments == ["--verify", "--deep", "--strict", Self.built]
                ? ProcessResult(status: 1, output: "a sealed resource is missing or invalid") : nil
        }
        #expect(install(runner).first == "\(Self.built): signature: a sealed resource is missing or invalid")
        #expect(!runner.executables.contains("/usr/bin/ditto"))
    }

    /// The trap of 2026-11-01: the build folder's modules registered and run instead of the installed ones.
    @Test func aModuleStillRegisteredOutsideTheInstalledAppIsAProblem() {
        let runner = Self.answers { command in
            guard command.arguments.first == "-mAv" else { return nil }
            return ProcessResult(
                status: 0,
                output: """
                         dev.gcqd.MacFS.BtrfsFS(0.1)\tU\td\t/Applications/MacFS.app/Contents/Extensions/BtrfsFS.appex
                         dev.gcqd.MacFS.ExtFSModule(0.1)\tU\td\t/tmp/b/MacFS.app/Contents/Extensions/ExtFSModule.appex
                         com.apple.fskit.exfat((null))\tU\td\t/System/Library/ExtensionKit/Extensions/com.apple.fskit.exfat.appex
                    """
            )
        }
        #expect(
            install(runner) == [
                "dev.gcqd.MacFS.ExtFSModule is registered at /tmp/b/MacFS.app/Contents/Extensions/ExtFSModule.appex, not in /Applications/MacFS.app"
            ]
        )
    }

    @Test func aModuleNotRegisteredAtAllIsAProblem() {
        let runner = Self.answers { command in
            guard command.arguments.first == "-mAv" else { return nil }
            return ProcessResult(
                status: 0,
                output:
                    "     dev.gcqd.MacFS.BtrfsFS(0.1)\tU\td\t/Applications/MacFS.app/Contents/Extensions/BtrfsFS.appex"
            )
        }
        #expect(install(runner) == ["dev.gcqd.MacFS.ExtFSModule is not registered"])
    }

    /// No installed app yet: nothing to keep, nothing moved.
    @Test func aFirstInstallKeepsNothing() {
        let runner = Self.answers {
            $0.executable == "/bin/mv" ? ProcessResult(status: 1, output: "No such file") : nil
        }
        #expect(install(runner).isEmpty)
    }

    @Test func aCopyThatFailsIsReportedAndStops() {
        let runner = Self.answers {
            $0.executable == "/usr/bin/ditto" ? ProcessResult(status: 1, output: "No space left") : nil
        }
        #expect(install(runner) == ["copy: No space left (the previous app is at /tmp/MacFS.app.previous)"])
        #expect(runner.executables.last == "/usr/bin/ditto")
    }

    /// Each required entitlement counts, not only the first: a module that is not sandboxed is refused too.
    @Test func aModuleThatIsNotSandboxedIsRefused() {
        let runner = Self.answers { command in
            guard command.arguments.last?.hasSuffix("ExtFSModule.appex") == true,
                command.arguments.contains("--entitlements")
            else { return nil }
            return ProcessResult(status: 0, output: "<key>com.apple.developer.fskit.fsmodule</key><true/>")
        }
        #expect(
            install(runner) == [
                "\(Self.built)/Contents/Extensions/ExtFSModule.appex: no com.apple.security.app-sandbox entitlement"
            ]
        )
    }

    /// The copy is verified where it landed.
    @Test func anInstalledSignatureThatDoesNotVerifyIsAProblem() {
        let runner = Self.answers {
            $0.arguments == ["--verify", "--deep", "--strict", "/Applications/MacFS.app"]
                ? ProcessResult(status: 1, output: "code has no resources but signature indicates they must be present")
                : nil
        }
        #expect(
            install(runner) == [
                "/Applications/MacFS.app: signature: code has no resources but signature indicates they must be present"
            ]
        )
    }

    /// The processes the installer stops, matched as `pkill -f` matches them (POSIX extended expressions on the command line):
    /// launchd starts the agent as `Contents/MacOS/macfs-agent`, relative, and a pattern with a leading slash left the old agent
    /// serving after every install (measured, diary 2026-11-02-04). The app itself is never stopped.
    @Test func theStaleProcessPatternMatchesTheAgentAsLaunchdStartsIt() {
        func matches(_ line: String) -> Bool {
            var expression = regex_t()
            guard regcomp(&expression, Installer.staleProcesses, REG_EXTENDED | REG_NOSUB) == 0 else { return false }
            defer { regfree(&expression) }
            return regexec(&expression, line, 0, nil, 0) == 0
        }
        #expect(matches("Contents/MacOS/macfs-agent"))
        #expect(matches("/Applications/MacFS.app/Contents/MacOS/macfs-agent"))
        #expect(matches("/Applications/MacFS.app/Contents/Extensions/ExtFSModule.appex/Contents/MacOS/ExtFSModule"))
        #expect(!matches("/Applications/MacFS.app/Contents/MacOS/MacFS"))
    }
}
