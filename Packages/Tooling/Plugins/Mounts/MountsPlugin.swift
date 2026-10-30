import Foundation
import PackagePlugin

/// `swift package mounts`: runs `macfs-tool mounts` against the repository root (two levels above this package).
@main
struct MountsPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "macfs-tool")
        let root = context.package.directoryURL.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = tool.url
        process.arguments = ["mounts", "--root", root.path] + arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("macfs-tool mounts exited with \(process.terminationStatus)")
        }
    }
}
