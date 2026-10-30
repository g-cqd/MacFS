import FSKit
import Observation

/// Which MacFS modules macOS knows about, and whether the user enabled them.
@MainActor @Observable
final class ExtensionStatus {
    struct Module: Identifiable {
        let id: String
        let enabled: Bool
    }

    private(set) var modules: [Module] = []
    private(set) var problem: String?

    func refresh() async {
        do {
            let installed = try await FSClient.shared.installedExtensions
            modules = installed.filter { $0.bundleIdentifier.hasPrefix("dev.gcqd.MacFS.") }
                .map { Module(id: $0.bundleIdentifier, enabled: $0.isEnabled) }
                .sorted { $0.id < $1.id }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func openSettings() {
        _ = FSClient.shared.openFileSystemExtensionsSettings()
    }
}
