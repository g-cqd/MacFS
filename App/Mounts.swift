import Darwin
import Foundation
import MountAgent
import MountKit
import Observation

/// The mounts the agent holds, and mounting the image the browser opened through it (roadmap 0039). The app opens the image
/// (the user chose it, so the sandbox lets it) and sends the descriptor, so the agent never opens a path in a protected folder.
/// Calls block on XPC: they run off the main actor.
@MainActor @Observable
final class Mounts {
    private(set) var records: [MountRecord] = []
    private(set) var problem: String?
    private(set) var busy = false

    func refresh() async {
        await run { (client) throws(MountError) in try client.list() }
    }

    /// Mounts the image at `url` (inside the browser's security scope) through the NFS proxy, at a point the agent chooses.
    func mount(_ url: URL) async {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            problem = "\(url.lastPathComponent) cannot be opened: errno \(errno)"
            return
        }
        defer { close(fd) }  // the agent holds its own duplicate
        await run { (client) throws(MountError) in
            _ = try client.mount(source: url.path, kind: .nfs, at: "", descriptor: fd)
            return try client.list()
        }
    }

    func unmount(_ record: MountRecord) async {
        await run { (client) throws(MountError) in
            try client.unmount(id: record.id)
            return try client.list()
        }
    }

    private func run(_ body: @escaping @Sendable (AgentClient) throws(MountError) -> [MountRecord]) async {
        busy = true
        defer { busy = false }
        let result =
            await Task.detached { () -> Result<[MountRecord], MountError> in
                do throws(MountError) { return .success(try body(try AgentConnection.client())) } catch {
                    return .failure(error)
                }
            }
            .value
        switch result {
            case .success(let records):
                self.records = records
                problem = nil
            case .failure(let error):
                problem = Self.describe(error)
        }
    }

    static func describe(_ error: MountError) -> String {
        switch error {
            case .agent(let text): "The mount agent did not answer (\(text)). Check it in Settings → Status."
            case .unavailable(_, let reason), .backend(let reason), .registry(let reason): reason
            case .mountPointInUse(let path): "\(path) is in use."
            case .notFound, .unrecognized: "That mount is no longer known."
            case .noBackend(let kind): "No \(kind) backend in this MacFS."
        }
    }
}
