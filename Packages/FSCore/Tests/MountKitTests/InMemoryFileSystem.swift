import FSCore

/// A file system held in a dictionary, for testing what sits above the readers.
struct InMemoryFileSystem: ReadOnlyFileSystem {
    struct Node {
        var attributes: NodeAttributes
        var children: [(String, UInt64)] = []
        var content: [UInt8] = []
    }

    let volume = VolumeDescription(
        format: "memory", label: "Memory", uuid: [UInt8](repeating: 1, count: 16), caseRule: .sensitive,
        maximumNameLength: 255)
    let rootID: UInt64
    var nodes: [UInt64: Node]

    /// A root (identifier `root`) with `count` files named f0, f1, ... with identifiers 1000, 1001, ...
    init(root: UInt64, files count: Int) {
        rootID = root
        var rootNode = Node(attributes: NodeAttributes(id: root, parent: root, kind: .directory))
        nodes = [:]
        for index in 0 ..< count {
            let id = UInt64(1000 + index)
            rootNode.children.append(("f\(index)", id))
            var file = Node(attributes: NodeAttributes(id: id, parent: root, kind: .regular))
            file.content = Array("content \(index)".utf8)
            file.attributes.size = UInt64(file.content.count)
            nodes[id] = file
        }
        nodes[root] = rootNode
    }

    func statistics() throws(DiskError) -> VolumeStatistics {
        VolumeStatistics(blockSize: 4096, totalBlocks: 10, freeBlocks: 5, files: 1)
    }

    func attributes(of id: UInt64) throws(DiskError) -> NodeAttributes {
        guard let node = nodes[id] else { throw .notFound }
        return node.attributes
    }

    func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        guard let node = nodes[directory] else { throw .notFound }
        guard let match = node.children.first(where: { Array($0.0.utf8) == name }) else { throw .notFound }
        return DirectoryEntry(name: name, id: match.1, kind: nodes[match.1]?.attributes.kind ?? .regular, nextCookie: 0)
    }

    func entries(of directory: UInt64, from cookie: UInt64, limit: Int) throws(DiskError) -> [DirectoryEntry] {
        guard let node = nodes[directory] else { throw .notFound }
        guard node.attributes.kind == .directory else { throw .notDirectory }
        let start = Int(min(cookie, UInt64(node.children.count)))
        return node.children[start ..< min(node.children.count, start + limit)].enumerated()
            .map { offset, child in
                DirectoryEntry(
                    name: Array(child.0.utf8), id: child.1, kind: nodes[child.1]?.attributes.kind ?? .regular,
                    nextCookie: UInt64(start + offset + 1))
            }
    }

    func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard let node = nodes[id] else { throw .notFound }
        let start = Int(min(offset, UInt64(node.content.count)))
        return Array(node.content[start ..< min(node.content.count, start + count)])
    }

    func readLink(_ id: UInt64) throws(DiskError) -> [UInt8] { throw .notSymlink }
}
