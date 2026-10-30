import FSCore
import MountKit

/// `fattr3` (RFC 1813 section 2.6) from a reader's attributes. Owners are the serving user's, as a
/// `noowners` mount would show them: Linux and Windows owners mean nothing on this Mac.
struct NFSAttributes: Sendable {
    let tree: MountedTree
    let owner: (uid: UInt32, gid: UInt32)
    let fsid: UInt64

    func write(_ node: NodeAttributes, into writer: inout XDRWriter) {
        writer.u32(Self.type(node.kind))
        writer.u32(UInt32(node.permissions))
        writer.u32(node.linkCount)
        writer.u32(owner.uid)
        writer.u32(owner.gid)
        writer.u64(node.size)
        writer.u64(node.allocatedSize)
        writer.u64(0)  // rdev
        writer.u64(fsid)
        writer.u64(tree.mountID(for: node.id))
        for time in [node.accessed, node.modified, node.changed] {
            writer.u32(UInt32(truncatingIfNeeded: max(0, time.seconds)))
            writer.u32(UInt32(max(0, time.nanoseconds)))
        }
    }

    /// `post_op_attr`: the attributes when they can be read, else nothing.
    func postOp(_ mountID: UInt64, into writer: inout XDRWriter) {
        guard let node = try? tree.fileSystem.attributes(of: tree.readerID(for: mountID)) else {
            return writer.bool(false)
        }
        writer.bool(true)
        write(node, into: &writer)
    }

    static func type(_ kind: NodeKind) -> UInt32 {
        switch kind {
            case .regular: 1
            case .directory: 2
            case .blockDevice: 3
            case .characterDevice: 4
            case .symlink: 5
            case .socket: 6
            case .fifo: 7
        }
    }
}
