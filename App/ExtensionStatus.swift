import AppSupport
import FSKit
import Foundation
import Observation
import ServiceManagement

/// What the system says about MacFS's modules, evaluated by `AppSupport.StatusEvaluation` (tested there).
@MainActor @Observable
final class ExtensionStatus {
    private(set) var checks: [StatusCheck] = []
    private(set) var summary = StatusEvaluation.Summary(state: .unknown, headline: "Checking…")
    private(set) var facts = SystemFacts(
        appPath: Bundle.main.bundlePath,
        modules: [:],
        queryFailure: nil,
        agent: .notRegistered
    )
    /// The launch agent in Contents/Library/LaunchAgents (roadmap 0039).
    static let agent = SMAppService.agent(plistName: "dev.gcqd.MacFS.agent.plist")
    private(set) var checkedAt: Date?

    func refresh() async {
        var modules: [String: Bool] = [:]
        var failure: String?
        do {
            for module in try await FSClient.shared.installedExtensions {
                modules[module.bundleIdentifier] = module.isEnabled
            }
        } catch {
            failure = error.localizedDescription
        }
        facts = SystemFacts(
            appPath: Bundle.main.bundlePath,
            modules: modules,
            queryFailure: failure,
            agent: Self.agentState()
        )
        checks = StatusEvaluation.checks(facts)
        summary = StatusEvaluation.summary(checks)
        checkedAt = Date()
    }

    var report: String { StatusEvaluation.report(checks, facts: facts) }

    static func agentState() -> SystemFacts.Agent {
        switch agent.status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            default: .notRegistered
        }
    }

    func perform(_ remedy: StatusCheck.Remedy) {
        switch remedy {
            case .openExtensionSettings:
                _ = FSClient.shared.openFileSystemExtensionsSettings()
            case .registerAgent:
                try? Self.agent.register()
                Task { await refresh() }
            case .openLoginItems:
                SMAppService.openSystemSettingsLoginItems()
            case .moveToApplications, .reinstall:
                // Out of process: revealing through NSWorkspace stats the path on the main thread, and a wedged volume would
                // pin the UI (Everest's finding).
                let reveal = Process()
                reveal.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                reveal.arguments = ["-R", Bundle.main.bundlePath]
                try? reveal.run()
        }
    }
}
