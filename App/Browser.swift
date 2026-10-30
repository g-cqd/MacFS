import FSCore
import Formats
import Foundation
import MountKit
import Observation

/// An image or device opened in the app itself: the backend that needs no extension at all.
@MainActor @Observable
final class Browser {
    struct Row: Identifiable, Hashable {
        let id: UInt64
        let name: String
        let kind: NodeKind
        let size: UInt64
    }

    private(set) var title = "No volume"
    private(set) var format: DiskFormat?
    private(set) var path: [(UInt64, String)] = []
    private(set) var rows: [Row] = []
    private(set) var problem: String?
    private var tree: MountedTree?
    private var scope: URL?

    func open(_ url: URL) {
        scope?.stopAccessingSecurityScopedResource()
        scope = url.startAccessingSecurityScopedResource() ? url : nil
        do {
            let source = try FileBlockSource(path: url.path)
            guard let format = DiskFormat.detect(source) else {
                throw DiskError.unsupported("no Btrfs, NTFS or ext volume")
            }
            let fileSystem = try format.open(source)
            tree = try MountedTree(fileSystem)
            self.format = format
            title = fileSystem.volume.label.isEmpty ? url.lastPathComponent : fileSystem.volume.label
            path = [(MountedTree.root, title)]
            try list()
        } catch {
            problem = String(describing: error)
        }
    }

    func enter(_ row: Row) {
        guard row.kind == .directory else { return }
        path.append((row.id, row.name))
        try? list()
    }

    func up(to index: Int) {
        guard index < path.count else { return }
        path.removeSubrange((index + 1)...)
        try? list()
    }

    private func list() throws {
        guard let tree, let directory = path.last?.0 else { return }
        var listed: [Row] = []
        var cookie: UInt64 = 0
        while true {
            let page = try tree.page(of: directory, from: cookie, includeDots: false, limit: 256)
            guard let last = page.last else { break }
            for entry in page {
                let size = (try? tree.fileSystem.attributes(of: tree.readerID(for: entry.mountID)).size) ?? 0
                listed.append(Row(id: entry.mountID, name: entry.displayName, kind: entry.kind, size: size))
            }
            cookie = last.nextCookie
        }
        rows = listed
        problem = nil
    }

    /// Copies a file out of the volume, a megabyte at a time.
    func export(_ row: Row, to destination: URL) throws {
        guard let tree else { return }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        while offset < row.size {
            let bytes = try tree.fileSystem.read(tree.readerID(for: row.id), at: offset, count: 1 << 20)
            if bytes.isEmpty { break }
            try handle.write(contentsOf: bytes)
            offset += UInt64(bytes.count)
        }
    }
}
