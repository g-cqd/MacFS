import AppSupport
import FSKit
import Foundation
import Observation

/// What the system says about MacFS's modules, evaluated by `AppSupport.StatusEvaluation` (tested there).
@MainActor @Observable
final class ExtensionStatus {
    private(set) var checks: [StatusCheck] = []
    private(set) var summary = StatusEvaluation.Summary(state: .unknown, headline: "Checking…")
    private(set) var facts = SystemFacts(appPath: Bundle.main.bundlePath, modules: [:], queryFailure: nil)
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
        facts = SystemFacts(appPath: Bundle.main.bundlePath, modules: modules, queryFailure: failure)
        checks = StatusEvaluation.checks(facts)
        summary = StatusEvaluation.summary(checks)
        checkedAt = Date()
    }

    var report: String { StatusEvaluation.report(checks, facts: facts) }

    func perform(_ remedy: StatusCheck.Remedy) {
        switch remedy {
            case .openExtensionSettings:
                _ = FSClient.shared.openFileSystemExtensionsSettings()
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
