import CryptoKit
import FSCore
import Foundation
import Testing

/// Conformance against a reference implementation (docs/conformance): `<image>.reference` is the image as the Linux kernel,
/// ntfs-3g or btrfs-progs presents it, one node per line, and its `fields` line names what that implementation owns. Every
/// owned field of every node must match what the reader reports.
enum ReferenceOracle {
    struct Node: Equatable, CustomStringConvertible {
        var type = "", mode = "", uid = "", gid = "", nlink = "", size = "", mtime = "", ctime = "", content = ""
        var description: String {
            "\(type) mode \(mode) \(uid):\(gid) links \(nlink) size \(size) m \(mtime) c \(ctime) \(content.prefix(16))"
        }
    }

    struct Reference {
        let tool: String
        let fields: Set<String>
        let nodes: [String: Node]
    }

    static func reference(_ name: String) throws -> Reference {
        let url = ImageOracle.directory.appendingPathComponent("\(name).reference")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        guard lines.count > 2, lines[0].hasPrefix("# reference: "), lines[1].hasPrefix("# fields: ") else {
            throw DiskError.corrupt("\(name).reference has no header")
        }
        var nodes: [String: Node] = [:]
        for line in lines.dropFirst(2) {
            let column = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard column.count == 10 else { throw DiskError.corrupt("\(name).reference: \(line)") }
            let type = ["f": "file", "d": "dir", "l": "link"][column[1]] ?? column[1]
            nodes[column[0]] = Node(
                type: type,
                mode: column[2],
                uid: column[3],
                gid: column[4],
                nlink: column[5],
                size: column[6],
                mtime: normalized(column[7]),
                ctime: normalized(column[8]),
                content: column[9]
            )
        }
        return Reference(
            tool: String(lines[0].dropFirst(13)),
            fields: Set(lines[1].dropFirst(10).split(separator: " ").map(String.init)),
            nodes: nodes
        )
    }

    /// `find`'s `%T@` (seconds, a point, ten digits) as seconds and nine digits.
    static func normalized(_ time: String) -> String {
        let parts = time.split(separator: ".", maxSplits: 1).map(String.init)
        let fraction = (parts.count > 1 ? parts[1] : "") + "000000000"
        return "\(parts[0]).\(fraction.prefix(9))"
    }

    static func time(_ value: Timestamp) -> String {
        let nanoseconds = String(value.nanoseconds)
        return "\(value.seconds).\(String(repeating: "0", count: 9 - nanoseconds.count))\(nanoseconds)"
    }

    /// What the reader reports, in the reference's terms.
    static func observed(_ fileSystem: any ReadOnlyFileSystem) throws -> [String: Node] {
        var nodes: [String: Node] = [:]
        try TreeWalk.visit(fileSystem, pageSize: 64) { (visit) throws(DiskError) in
            let attributes = try fileSystem.attributes(of: visit.entry.id)
            var node = Node(
                type: "file",
                mode: String(attributes.permissions, radix: 8),
                uid: String(attributes.uid),
                gid: String(attributes.gid),
                nlink: String(attributes.linkCount),
                size: String(attributes.size),
                mtime: time(attributes.modified),
                ctime: time(attributes.changed),
                content: "-"
            )
            switch visit.entry.kind {
                case .directory:
                    node.type = "dir"
                case .symlink:
                    node.type = "link"
                    node.content = String(decoding: try fileSystem.readLink(visit.entry.id), as: UTF8.self)
                default:
                    var hash = SHA256()
                    var offset: UInt64 = 0
                    while offset < attributes.size {
                        let bytes = try fileSystem.read(visit.entry.id, at: offset, count: 1 << 20)
                        guard !bytes.isEmpty else { throw .corrupt("short read at \(offset) of \(visit.path)") }
                        hash.update(data: bytes)
                        offset += UInt64(bytes.count)
                    }
                    node.content = hash.finalize().map { String(format: "%02x", $0) }.joined()
            }
            nodes[visit.path] = node
        }
        return nodes
    }

    /// Every owned field of every node, and the same set of nodes. Returns the mismatches, one line each, for the caller to
    /// record (a known divergence is named, with its reason, by the caller's `accepted`).
    static func compare(_ fileSystem: any ReadOnlyFileSystem, reference name: String) throws -> [String] {
        let reference = try reference(name)
        let actual = try observed(fileSystem)
        var problems: [String] = []
        for (path, expected) in reference.nodes.sorted(by: { $0.key < $1.key }) {
            guard let node = actual[path] else {
                problems.append("\(path): missing")
                continue
            }
            for field in fields(of: expected, against: node, owned: reference.fields) {
                problems.append("\(path): \(field)")
            }
        }
        for path in actual.keys.sorted() where reference.nodes[path] == nil {
            problems.append("\(path): not in the reference")
        }
        if reference.nodes.count < 300 {
            problems.append("only \(reference.nodes.count) nodes: not the generated reference")
        }
        return problems
    }

    private static func fields(of expected: Node, against node: Node, owned: Set<String>) -> [String] {
        var differ: [String] = []
        func check(_ field: String, _ want: String, _ got: String) {
            if owned.contains(field), want != got { differ.append("\(field) \(want), read \(got)") }
        }
        check("type", expected.type, node.type)
        check("mode", expected.mode, node.mode)
        check("uid", expected.uid, node.uid)
        check("gid", expected.gid, node.gid)
        check("nlink", expected.nlink, node.nlink)
        if expected.type == "dir" {
            check("dirsize", expected.size, node.size)
        } else {
            check("size", expected.size, node.size)
        }
        check("mtime", expected.mtime, node.mtime)
        check("ctime", expected.ctime, node.ctime)
        check("content", expected.content, node.content)
        return differ
    }
}
