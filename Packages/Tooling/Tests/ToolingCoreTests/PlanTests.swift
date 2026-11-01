import Synchronization
import Testing
import ToolingCore

@Suite struct PlanTests {
    static let root = "/repo"

    @Test func aDryRunPrintsEveryStepAndRunsNothing() throws {
        let runner = RecordingRunner()
        let plan = Plan(steps: [Command("/bin/echo", ["a"]), Command("/bin/echo", ["b c"])])
        let report = try plan.execute(with: runner, dryRun: true)
        #expect(runner.executables.isEmpty)
        #expect(report.lines == ["/bin/echo a", "/bin/echo 'b c'"])
        #expect(report.failed.isEmpty)
    }

    @Test func aRealRunRunsEveryStepAndCollectsFailures() throws {
        let runner = RecordingRunner {
            $0.arguments == ["bad"] ? ProcessResult(status: 1, output: "boom") : ProcessResult(status: 0, output: "")
        }
        let plan = Plan(steps: [Command("/x", ["ok"]), Command("/x", ["bad"]), Command("/x", ["ok2"])])
        let report = try plan.execute(with: runner, dryRun: false)
        #expect(runner.commands.withLock { $0.count } == 3, "a failing gate must not hide the gates after it")
        #expect(report.failed == [Command("/x", ["bad"])])
    }

    @Test func imagesRunTheInnerScriptInTheConfiguredContainer() {
        let plan = TestImages.plan(root: Self.root, container: "/opt/homebrew/bin/container")
        #expect(plan.steps.count == 1)
        let step = plan.steps[0]
        #expect(step.executable == "/opt/homebrew/bin/container")
        #expect(step.arguments.prefix(2) == ["run", "--rm"])
        #expect(step.arguments.contains("/repo/TestImages:/work"))
        #expect(step.arguments.contains("/repo/Scripts:/scripts"))
        #expect(step.arguments.last == "/scripts/make-test-images.inner.sh")
        #expect(step.arguments.contains { $0.hasPrefix("alpine:") }, "the image is pinned by tag")
    }

    /// The reference implementations mount the images (the Linux kernel for ext, ntfs-3g through FUSE for NTFS), and
    /// ntfs-3g builds the NTFS image from the full tree: both need the container's capabilities.
    @Test func imagesRunWithTheCapabilitiesToMount() {
        for kind in TestImages.Kind.allCases {
            let arguments = TestImages.plan(root: Self.root, container: "/c", kind: kind).steps[0].arguments
            guard let flag = arguments.firstIndex(of: "--cap-add") else {
                Issue.record("no --cap-add (\(kind))")
                continue
            }
            #expect(arguments[flag + 1] == "ALL")
            #expect(flag < arguments.firstIndex(of: TestImages.image)!, "run options come before the image")
        }
    }

    /// When Alpine's CDN crawls, a mirror host reaches the payload as APK_MIRROR (a container option, before the image),
    /// which rewrites the container's repositories; without one, nothing is passed.
    @Test func aMirrorReachesThePayload() {
        for kind in TestImages.Kind.allCases {
            let arguments = TestImages.plan(root: Self.root, container: "/c", kind: kind, mirror: "ftp.example.org")
                .steps[0].arguments
            guard let flag = arguments.firstIndex(of: "-e") else {
                Issue.record("no -e (\(kind))")
                continue
            }
            #expect(arguments[flag + 1] == "APK_MIRROR=ftp.example.org")
            #expect(flag < arguments.firstIndex(of: TestImages.image)!, "run options come before the image")
            #expect(!TestImages.plan(root: Self.root, container: "/c", kind: kind).steps[0].arguments.contains("-e"))
        }
    }

    @Test func benchImagesRunTheirOwnPayload() {
        let plan = TestImages.plan(root: Self.root, container: "/c", kind: .bench)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].arguments.last == "/scripts/make-bench-images.inner.sh")
        #expect(
            plan.steps[0].arguments.contains("/repo/BenchImages:/work"),
            "bench images live apart from the test images"
        )
    }

    /// The reference test suites (e2fsprogs' and btrfs-progs' images) are fetched and unpacked in the container, into a
    /// directory of their own: they are a hostile corpus, not an oracle of trees.
    @Test func theCorpusIsTheReferenceSuites() {
        let plan = TestImages.plan(root: Self.root, container: "/c", kind: .corpus)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].arguments.last == "/scripts/fetch-reference-suites.inner.sh")
        #expect(plan.steps[0].arguments.contains("/repo/TestCorpus:/work"))
        #expect(TestImages.Kind.corpus.directory == "TestCorpus")
    }

    @Test func gatesCoverEveryToolTheWhitePaperNames() {
        let tools = ToolPaths(
            swift: "/s",
            swiftlint: "/l",
            deadwood: "/d",
            dolly: "/o",
            arcleak: "/a",
            fcheck: "/f",
            modeler: "/m",
            java: "/j",
            tla2tools: "/t.jar",
            lake: "/k"
        )
        let plan = Gates.plan(root: Self.root, tools: tools)
        let used = Set(plan.steps.map(\.executable))
        #expect(used == ["/s", "/l", "/d", "/o", "/a", "/f", "/m", "/j", "/k"])
        #expect(plan.steps.contains(Command("/k", ["-d", "/repo/Proofs", "build"])), "the Lean proofs are a gate")
        // The pre-commit hook lints manifests, benchmarks and plugins; a gate that skips them lets a commit be blocked.
        let format = plan.steps.first { $0.executable == "/s" }?.arguments ?? []
        for path in [
            "Packages/FSCore/Package.swift", "Packages/Tooling/Package.swift", "Packages/FSCore/Benchmarks",
            "Packages/Tooling/Plugins"
        ] {
            #expect(format.contains("/repo/\(path)"), "format gate misses \(path)")
        }
        for step in plan.steps where ["/d", "/o", "/a", "/f"].contains(step.executable) {
            #expect(step.arguments.contains("--strict"), "\(step.executable) must fail on a warning")
        }
        #expect(
            plan.steps.contains {
                $0.executable == "/s" && $0.arguments.contains("--strict") && $0.arguments.contains("lint")
            }
        )
    }
}
