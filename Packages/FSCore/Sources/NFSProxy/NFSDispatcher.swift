import FSCore
public import MountKit

/// The whole server as a function: one RPC call in, one reply out (nil drops a record that is not a call).
/// No sockets, no state beyond the tree, so every procedure is tested without a network.
public final class NFSDispatcher: Sendable {
    let tree: MountedTree
    let handles: FileHandles
    let attributes: NFSAttributes

    public init(tree: MountedTree, owner: (uid: UInt32, gid: UInt32)) {
        self.tree = tree
        let volume = tree.fileSystem.volume
        handles = FileHandles(volume: volume)
        var fsid: UInt64 = 0
        for byte in (volume.uuid + [UInt8](repeating: 0, count: 8)).prefix(8) { fsid = fsid << 8 | UInt64(byte) }
        attributes = NFSAttributes(tree: tree, owner: owner, fsid: fsid)
    }

    public func handle(_ record: [UInt8]) -> [UInt8]? {
        var reader = XDRReader(record)
        guard let call = RPCCall(&reader) else { return nil }
        guard call.program == NFSProgram.number || call.program == MountProgram.number else {
            return call.reply(status: 1)
        }
        guard call.version == 3 else { return call.reply(status: 2) }
        do throws(XDRError) {
            let results =
                call.program == MountProgram.number
                ? try MountProgram.handle(call.procedure, &reader, root: handles.handle(MountedTree.root))
                : try NFSProgram(dispatcher: self).handle(call.procedure, &reader)
            guard let results else { return call.reply(status: 3) }
            return call.reply(status: 0, results: results)
        } catch {
            return call.reply(status: 4)
        }
    }
}
