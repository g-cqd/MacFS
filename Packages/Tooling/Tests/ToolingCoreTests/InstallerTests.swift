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
                default:
                    return ProcessResult(status: 0, output: "")
            }
        }
    }

    func install(_ runner: RecordingRunner) -> [String] {
        Installer(
            runner: runner,
            root: "/repo",
            derivedData: "/dd",
            installed: "/Applications/MacFS.app",
            previous: "/tmp/MacFS.app.previous",
            team: "NP94WB3P75",
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
            // The build's copy unregistered and removed, so its modules cannot be the ones that run; no `pluginkit -r`/`-a`,
            // which lost a module's enablement in System Settings (diary 2026-11-01-07).
            Command(lsregister, ["-u", Self.built]),
            Command("/bin/rm", ["-rf", Self.built]),
            Command(lsregister, ["-f", "/Applications/MacFS.app"]),
            Command("/usr/bin/pkill", ["-9", "-f", "/Contents/Extensions/[^/]*\\.appex/|/Contents/MacOS/macfs-agent"]),
            Command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "/Applications/MacFS.app"]),
            Command("/usr/bin/pluginkit", ["-mAv", "-p", "com.apple.fskit.fsmodule"])
        ]
        #expect(commands == expected)
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
}
