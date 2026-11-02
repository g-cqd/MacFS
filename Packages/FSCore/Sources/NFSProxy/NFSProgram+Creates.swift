import FSCore
import MountKit

/// CREATE, MKDIR, SYMLINK and LINK (RFC 1813, roadmap 0046): the new node answered as `post_op_fh3` and its attributes, then
/// the directory's `wcc_data`. CREATE is UNCHECKED (an existing file is kept, its attributes set), GUARDED (an existing name is
/// NFS3ERR_EXIST) or EXCLUSIVE (the client's verifier kept in the access and modification times, as Linux's server keeps it,
/// so a retransmission finds its own file).
extension NFSProgram {
    func create(_ arguments: inout XDRReader, _ writer: any WritableFileSystem, _ results: inout XDRWriter)
        throws(XDRError)
    {
        let (handle, name) = try Self.directoryOperation(&arguments)
        let how = try arguments.u32()
        guard how <= 2 else { throw .truncated }
        let attributes = how == 2 ? SetAttributes3() : try SetAttributes3(&arguments)
        let verifier = how == 2 ? Self.verifierTimes(try arguments.fixed(8)) : nil
        answerMade(&results, handle) { (parent) throws(NFSFailure) -> UInt64 in
            let directory = tree.readerID(for: parent)
            if let existing = try? entry(name, in: parent) {
                if let verifier {
                    let stored = try NFSFailure.attempt { () throws(DiskError) in
                        try tree.fileSystem.attributes(of: existing.id)
                    }
                    guard stored.accessed == verifier.accessed, stored.modified == verifier.modified else {
                        throw NFSFailure(NFSStatus.exists)
                    }
                    return existing.id
                }
                guard how == 0, existing.kind == .regular else { throw NFSFailure(NFSStatus.exists) }
                try NFSFailure.attempt { () throws(DiskError) in try attributes.apply(to: existing.id, through: writer)
                }
                return existing.id
            }
            return try NFSFailure.attempt { () throws(DiskError) in
                let id = try writer.create(
                    name,
                    kind: .regular,
                    in: directory,
                    mode: Self.mode(attributes, fallback: 0o644),
                    owner: owner(attributes)
                )
                if let verifier {
                    try writer.setAttributes(id, verifier)
                } else {
                    try attributes.apply(to: id, through: writer)
                }
                return id
            }
        }
    }

    /// MKDIR (`kind` directory) and SYMLINK (`kind` symlink, its target after the attributes).
    func make(
        _ kind: NodeKind,
        _ arguments: inout XDRReader,
        _ writer: any WritableFileSystem,
        _ results: inout XDRWriter
    )
        throws(XDRError)
    {
        let (handle, name) = try Self.directoryOperation(&arguments)
        let attributes = try SetAttributes3(&arguments)
        let target = kind == .symlink ? try arguments.opaque(maximum: 4096) : []
        answerMade(&results, handle) { (parent) throws(NFSFailure) -> UInt64 in
            try NFSFailure.attempt { () throws(DiskError) in
                let directory = tree.readerID(for: parent)
                if kind == .symlink {
                    return try writer.createSymlink(name, target: target, in: directory, owner: owner(attributes))
                }
                let id = try writer.create(
                    name,
                    kind: .directory,
                    in: directory,
                    mode: Self.mode(attributes, fallback: 0o755),
                    owner: owner(attributes)
                )
                var rest = attributes
                rest.mode = nil
                try rest.apply(to: id, through: writer)
                return id
            }
        }
    }

    func link(_ arguments: inout XDRReader, _ writer: any WritableFileSystem, _ results: inout XDRWriter)
        throws(XDRError)
    {
        let file = try arguments.opaque(maximum: 64)
        let (handle, name) = try Self.directoryOperation(&arguments)
        do throws(NFSFailure) {
            let id = try resolve(file)
            let parent = try resolve(handle)
            try NFSFailure.attempt { () throws(DiskError) in
                try writer.link(tree.readerID(for: id), as: name, in: tree.readerID(for: parent))
            }
            results.u32(NFSStatus.ok)
        } catch {
            results.u32(error.status)
        }
        if let id = dispatcher.handles.mountID(file) {
            dispatcher.attributes.postOp(id, into: &results)
        } else {
            results.bool(false)
        }
        wcc(dispatcher.handles.mountID(handle), &results)
    }

    /// Runs `body` on the directory `handle` names; it returns the new node's reader identifier.
    private func answerMade(
        _ results: inout XDRWriter,
        _ handle: [UInt8],
        _ body: (UInt64) throws(NFSFailure) -> UInt64
    ) {
        do throws(NFSFailure) {
            let parent = try resolve(handle)
            let made = try body(parent)
            let id = try NFSFailure.attempt { () throws(DiskError) in try tree.checkedMountID(for: made) }
            results.u32(NFSStatus.ok)
            results.bool(true)
            results.opaque(dispatcher.handles.handle(id))
            dispatcher.attributes.postOp(id, into: &results)
        } catch {
            results.u32(error.status)
        }
        wcc(dispatcher.handles.mountID(handle), &results)
    }

    /// The owner the attributes name, else the serving user's.
    private func owner(_ attributes: SetAttributes3) -> (uid: UInt32, gid: UInt32) {
        (attributes.uid ?? dispatcher.attributes.owner.uid, attributes.gid ?? dispatcher.attributes.owner.gid)
    }

    private static func mode(_ attributes: SetAttributes3, fallback: UInt16) -> UInt16 {
        attributes.mode.map { UInt16(truncatingIfNeeded: $0 & 0o7777) } ?? fallback
    }

    /// An EXCLUSIVE create's verifier as the times that keep it: its first four bytes the access time, the last four the
    /// modification time.
    static func verifierTimes(_ verifier: [UInt8]) -> AttributeChanges {
        func seconds(_ bytes: ArraySlice<UInt8>) -> Timestamp {
            Timestamp(seconds: Int64(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }), nanoseconds: 0)
        }
        return AttributeChanges(accessed: seconds(verifier.prefix(4)), modified: seconds(verifier.suffix(4)))
    }
}
