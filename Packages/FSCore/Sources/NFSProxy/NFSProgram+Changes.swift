import FSCore
import MountKit

/// The changing procedures (RFC 1813, roadmap 0046), answered through the volume's writer. Arguments are read whole before
/// anything changes; a failure answers its status and the `wcc_data` (or attributes) the procedure's failure carries. Weak
/// cache consistency is sent without the attributes before (`pre_op_attr` false): the client then refetches.
extension NFSProgram {
    func change(_ procedure: UInt32, _ arguments: inout XDRReader, _ writer: any WritableFileSystem)
        throws(XDRError) -> XDRWriter
    {
        var results = XDRWriter()
        // @fc:disable replace-not-durable -- NFS's RENAME procedure, not a file rename: the writer orders its own writes
        switch procedure {
            case 2: try setattr(&arguments, writer, &results)
            case 7: try write(&arguments, writer, &results)
            case 8: try create(&arguments, writer, &results)
            case 9: try make(.directory, &arguments, writer, &results)
            case 10: try make(.symlink, &arguments, writer, &results)
            case 12, 13: try remove(&arguments, directory: procedure == 13, writer, &results)
            case 14: try rename(&arguments, writer, &results)
            case 15: try link(&arguments, writer, &results)
            default: try commit(&arguments, writer, &results)
        }
        // @fc:enable replace-not-durable
        return results
    }

    /// `diropargs3`: a directory's handle and a name in it.
    static func directoryOperation(_ arguments: inout XDRReader) throws(XDRError) -> (handle: [UInt8], name: [UInt8]) {
        (try arguments.opaque(maximum: 64), try arguments.opaque(maximum: 255))
    }

    /// The mount identifier a handle names.
    func resolve(_ handle: [UInt8]) throws(NFSFailure) -> UInt64 {
        guard let id = dispatcher.handles.mountID(handle) else { throw NFSFailure(NFSStatus.badHandle) }
        return id
    }

    /// `wcc_data` for `id` after the change; nothing for an identifier not resolved.
    func wcc(_ id: UInt64?, _ results: inout XDRWriter) {
        results.bool(false)
        if let id { dispatcher.attributes.postOp(id, into: &results) } else { results.bool(false) }
    }

    /// The stored entry a client's name finds in `directory` (decomposed names find precomposed ones, roadmap 0022).
    func entry(_ name: [UInt8], in directory: UInt64) throws(NFSFailure) -> DirectoryEntry {
        try NFSFailure.attempt { () throws(DiskError) in
            try tree.fileSystem.lookupCanonical(name, in: tree.readerID(for: directory))
        }
    }

    /// Runs `body`, then answers OK or its failure, followed by the `wcc_data` of `ids` either way.
    func answerWcc(_ results: inout XDRWriter, _ ids: [UInt64?], _ body: () throws(NFSFailure) -> Void) {
        do throws(NFSFailure) {
            try body()
            results.u32(NFSStatus.ok)
        } catch {
            results.u32(error.status)
        }
        for id in ids { wcc(id, &results) }
    }

    private func setattr(_ arguments: inout XDRReader, _ writer: any WritableFileSystem, _ results: inout XDRWriter)
        throws(XDRError)
    {
        let handle = try arguments.opaque(maximum: 64)
        let attributes = try SetAttributes3(&arguments)
        let guardTime: Timestamp? =
            try arguments.bool()
            ? Timestamp(
                seconds: Int64(try arguments.u32()),
                nanoseconds: Int32(truncatingIfNeeded: try arguments.u32())
            )
            : nil
        answerWcc(&results, [dispatcher.handles.mountID(handle)]) { () throws(NFSFailure) in
            let reader = tree.readerID(for: try resolve(handle))
            if let guardTime {
                let changed = try NFSFailure.attempt { () throws(DiskError) in
                    try tree.fileSystem.attributes(of: reader).changed
                }
                guard changed == guardTime else { throw NFSFailure(NFSStatus.notSynchronized) }
            }
            try NFSFailure.attempt { () throws(DiskError) in try attributes.apply(to: reader, through: writer) }
        }
    }

    private func write(_ arguments: inout XDRReader, _ writer: any WritableFileSystem, _ results: inout XDRWriter)
        throws(XDRError)
    {
        let handle = try arguments.opaque(maximum: 64)
        let offset = try arguments.u64()
        let count = try arguments.u32()
        let stable = try arguments.u32()
        let data = try arguments.opaque(maximum: Int(Self.maximumRead))
        let bytes = Array(data.prefix(Int(count)))
        answerVerified(&results, handle) { (id) throws(DiskError) in
            try writer.write(tree.readerID(for: id), at: offset, bytes)
            if stable != 0 { try writer.synchronize() }
        } success: { results in
            results.u32(UInt32(bytes.count))
            results.u32(stable == 0 ? 0 : 2)  // UNSTABLE, else FILE_SYNC: data and metadata are on the device
        }
    }

    private func commit(_ arguments: inout XDRReader, _ writer: any WritableFileSystem, _ results: inout XDRWriter)
        throws(XDRError)
    {
        let handle = try arguments.opaque(maximum: 64)
        _ = try arguments.u64()
        _ = try arguments.u32()
        answerVerified(&results, handle) { (_) throws(DiskError) in
            try writer.synchronize()
        } success: { _ in
        }
    }

    /// WRITE's and COMMIT's answer: OK, the file's `wcc_data`, what `success` adds, the write verifier; or the failure and the
    /// `wcc_data`.
    private func answerVerified(
        _ results: inout XDRWriter,
        _ handle: [UInt8],
        _ body: (UInt64) throws(DiskError) -> Void,
        success: (inout XDRWriter) -> Void
    ) {
        do throws(NFSFailure) {
            let id = try resolve(handle)
            try NFSFailure.attempt { () throws(DiskError) in try body(id) }
            results.u32(NFSStatus.ok)
            wcc(id, &results)
            success(&results)
            results.fixed(dispatcher.writeVerifier)
        } catch {
            results.u32(error.status)
            wcc(dispatcher.handles.mountID(handle), &results)
        }
    }

    /// REMOVE (a non-directory) and RMDIR (a directory).
    private func remove(
        _ arguments: inout XDRReader,
        directory: Bool,
        _ writer: any WritableFileSystem,
        _ results: inout XDRWriter
    ) throws(XDRError) {
        let (handle, name) = try Self.directoryOperation(&arguments)
        answerWcc(&results, [dispatcher.handles.mountID(handle)]) { () throws(NFSFailure) in
            let parent = try resolve(handle)
            let found = try entry(name, in: parent)
            if directory, found.kind != .directory { throw NFSFailure(NFSStatus.notDirectory) }
            if !directory, found.kind == .directory { throw NFSFailure(NFSStatus.isDirectory) }
            try NFSFailure.attempt { () throws(DiskError) in
                try writer.remove(found.name, from: tree.readerID(for: parent))
            }
        }
    }

    private func rename(_ arguments: inout XDRReader, _ writer: any WritableFileSystem, _ results: inout XDRWriter)
        throws(XDRError)
    {
        let (from, name) = try Self.directoryOperation(&arguments)
        let (to, newName) = try Self.directoryOperation(&arguments)
        answerWcc(&results, [dispatcher.handles.mountID(from), dispatcher.handles.mountID(to)]) {
            () throws(NFSFailure) in
            let source = try resolve(from)
            let destination = try resolve(to)
            let found = try entry(name, in: source)
            try NFSFailure.attempt { () throws(DiskError) in
                try writer.rename(
                    found.name,
                    in: tree.readerID(for: source),
                    to: newName,
                    in: tree.readerID(for: destination)
                )
            }
        }
    }
}
