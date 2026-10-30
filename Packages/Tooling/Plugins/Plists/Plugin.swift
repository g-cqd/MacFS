import Foundation
import PackagePlugin

/// `swift package plists`: runs `macfs-tool plists` against the repository root (two levels above this package).
@main
struct PlistsPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "macfs-tool")
        let root = context.package.directoryURL.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = tool.url
        process.arguments = ["plists", "--root", root.path] + arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("macfs-tool plists exited with \(process.terminationStatus)")
        }
    }
}
