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

    @Test func benchImagesRunTheirOwnPayload() {
        let plan = TestImages.plan(root: Self.root, container: "/c", bench: true)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].arguments.last == "/scripts/make-bench-images.inner.sh")
        #expect(
            plan.steps[0].arguments.contains("/repo/BenchImages:/work"), "bench images live apart from the test images")
    }

    @Test func gatesCoverEveryToolTheWhitePaperNames() {
        let tools = ToolPaths(
            swift: "/s", swiftlint: "/l", deadwood: "/d", dolly: "/o", arcleak: "/a", fcheck: "/f", modeler: "/m",
            java: "/j",
            tla2tools: "/t.jar", lake: "/k")
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
            })
    }
}
