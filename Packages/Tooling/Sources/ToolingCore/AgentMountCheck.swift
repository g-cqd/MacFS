public import AppSupport

/// The agent path of the end-to-end check (roadmap 0039): each test image cloned into the app's container (where the sandboxed
/// app may open it), mounted by the installed app through its agent (`MacFS --mount-image`), compared with its manifest, refused a
/// write, unmounted through the app, and the clone removed, whatever failed before.
///
/// `launch` runs the installed app with arguments and returns the result it wrote (`AutomationResult`), nil when it wrote none.
public struct AgentMountCheck: Sendable {
    let runner: any ProcessRunning
    let root: String
    let container: String
    let launch: @Sendable ([String]) -> AutomationResult?
    let verification: MountVerification

    public init(
        runner: any ProcessRunning,
        root: String,
        container: String,
        launch: @escaping @Sendable ([String]) -> AutomationResult?,
        verification: MountVerification
    ) {
        self.runner = runner
        self.root = root
        self.container = container
        self.launch = launch
        self.verification = verification
    }

    public func run(_ target: MountCheck.Target) -> MountCheck.Outcome {
        let image = "\(root)/TestImages/\(target.image)"
        let clone = "\(container)/agentcheck-\(target.image).img"
        // An APFS clone (`cp -c`): no bytes copied, and the original stays out of the app's reach.
        let copied = try? runner.run(Command("/bin/cp", ["-c", "\(image).img", clone]))
        guard let copied, copied.status == 0 else {
            return MountCheck.Outcome(target: target, problems: ["clone: \(copied?.output ?? "did not run")"])
        }
        defer { _ = try? runner.run(Command("/bin/rm", ["-f", clone])) }
        let mounted: (id: String, point: String)
        switch launch(["--mount-image", clone]) {
            case .mounted(let id, let point)?:
                mounted = (id, point)
            case .failed(let text)?:
                return failed(target, "mount: \(text)")
            case .done?:
                return failed(target, "mount: MacFS answered ok without a mount")
            case nil:
                return failed(
                    target,
                    "mount: MacFS gave no result (is it installed in /Applications, its agent registered?)"
                )
        }
        var problems = verification.problems(at: mounted.point, manifest: "\(image).manifest", extra: target.extra)
        problems += AutomationResult.unmountProblems(launch(["--unmount", mounted.id]))
        return MountCheck.Outcome(target: target, problems: problems)
    }

    private func failed(_ target: MountCheck.Target, _ problem: String) -> MountCheck.Outcome {
        MountCheck.Outcome(target: target, problems: [problem])
    }
}
