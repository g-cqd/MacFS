public import AppSupport

/// The agent's writable path (roadmap 0046): a fresh copy in the app's container (``WriteCheck/prepare(_:root:in:)``), mounted
/// writable by the installed app through its agent (`--mount-image PATH --writable`), changed by the write check's operations,
/// unmounted through the app, then judged by the format's checker. `launch` runs the installed app and returns its result.
public struct AgentWriteCheck: Sendable {
    let runner: any ProcessRunning
    let launch: @Sendable ([String]) -> AutomationResult?
    let checker: @Sendable (WriteCheck.Target, String, [String: String]) -> [String]

    public init(
        runner: any ProcessRunning,
        launch: @escaping @Sendable ([String]) -> AutomationResult?,
        checker: @escaping @Sendable (WriteCheck.Target, String, [String: String]) -> [String]
    ) {
        self.runner = runner
        self.launch = launch
        self.checker = checker
    }

    public func run(_ target: WriteCheck.Target, in workspace: WriteCheck.Workspace) -> MountCheck.Outcome {
        let outcome = { (problems: [String]) in
            MountCheck.Outcome(target: .init(image: target.image, type: target.type, extra: []), problems: problems)
        }
        let mounted: (id: String, point: String)
        switch launch(["--mount-image", workspace.image, "--writable"]) {
            case .mounted(let id, let point)?: mounted = (id, point)
            case .failed(let text)?: return outcome(["mount: \(text)"])
            case .done?: return outcome(["mount: MacFS answered ok without a mount"])
            case nil: return outcome(["mount: MacFS gave no result (installed, its agent registered?)"])
        }
        var problems = WriteCheck.change(at: mounted.point, payload: workspace.payload, runner: runner)
        problems += AutomationResult.unmountProblems(launch(["--unmount", mounted.id]))
        return outcome(problems + checker(target, workspace.image, workspace.expected))
    }
}
