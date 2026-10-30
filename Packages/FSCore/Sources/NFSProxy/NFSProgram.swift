import FSCore
import MountKit

/// NFS version 3 (RFC 1813), read-only: every procedure that would change the volume answers NFS3ERR_ROFS.
struct NFSProgram {
    static let number: UInt32 = 100_003
    static let maximumRead: UInt32 = 1 << 20

    /// How many empty `pre_op_attr`/`post_op_attr` pairs follow the status of each refused mutation.
    private static let refusalBodies: [UInt32: Int] = [
        2: 2, 7: 2, 8: 2, 9: 2, 10: 2, 11: 2, 12: 2, 13: 2, 14: 4, 15: 3, 21: 2
    ]

    /// The procedures answered with data: GETATTR, LOOKUP, ACCESS, READLINK, READ, READDIR(PLUS), FSSTAT, FSINFO, PATHCONF.
    private static let reads: Set<UInt32> = [1, 3, 4, 5, 6, 16, 17, 18, 19, 20]

    let dispatcher: NFSDispatcher
    var tree: MountedTree { dispatcher.tree }

    func handle(_ procedure: UInt32, _ arguments: inout XDRReader) throws(XDRError) -> XDRWriter? {
        var results = XDRWriter()
        if procedure == 0 { return results }
        if let falses = Self.refusalBodies[procedure] {
            results.u32(NFSStatus.readOnly)
            for _ in 0 ..< falses { results.bool(false) }
            return results
        }
        // An unknown procedure is PROC_UNAVAIL, decided before any argument is read (else it reads as garbage).
        guard Self.reads.contains(procedure) else { return nil }
        let handle = try arguments.opaque(maximum: 64)
        guard let id = dispatcher.handles.mountID(handle) else {
            results.u32(NFSStatus.badHandle)
            results.bool(false)
            return results
        }
        switch procedure {
            case 1: getattr(id, &results)
            case 3: lookup(id, try arguments.opaque(maximum: 255), &results)
            case 4: access(id, try arguments.u32(), &results)
            case 5: readlink(id, &results)
            case 6: read(id, try arguments.u64(), try arguments.u32(), &results)
            case 16, 17:
                let cookie = try arguments.u64()
                let verifier = try arguments.u64()
                let directoryLimit = try arguments.u32()
                let limit = procedure == 17 ? try arguments.u32() : directoryLimit
                list(id, cookie: cookie, verifier: verifier, limit: Int(limit), plus: procedure == 17, &results)
            case 18: fsstat(id, &results)
            case 19: fsinfo(id, &results)
            case 20: pathconf(id, &results)
            default: return nil
        }
        return results
    }

    /// Runs `body`, writing its status: OK then the body, or the error status then the `post_op_attr` of
    /// `failureAttributes` (none when nil).
    func answer(
        _ results: inout XDRWriter, failureAttributes id: UInt64?, _ body: (inout XDRWriter) throws(DiskError) -> Void
    ) {
        var success = XDRWriter()
        do throws(DiskError) {
            try body(&success)
            results.u32(NFSStatus.ok)
            results.append(success)
        } catch {
            results.u32(error == .notFound ? NFSStatus.stale : NFSStatus.of(error))
            if let id { dispatcher.attributes.postOp(id, into: &results) }
        }
    }

    private func getattr(_ id: UInt64, _ results: inout XDRWriter) {
        answer(&results, failureAttributes: nil) { (writer) throws(DiskError) in
            dispatcher.attributes.write(try tree.fileSystem.attributes(of: tree.readerID(for: id)), into: &writer)
        }
    }

    private func lookup(_ directory: UInt64, _ name: [UInt8], _ results: inout XDRWriter) {
        do throws(DiskError) {
            let entry: UInt64
            switch name {
                case [0x2E]: entry = directory
                case [0x2E, 0x2E]:
                    entry = tree.parentMountID(of: try tree.fileSystem.attributes(of: tree.readerID(for: directory)))
                default:
                    entry = try tree.checkedMountID(
                        for: try tree.fileSystem.lookup(name, in: tree.readerID(for: directory)).id)
            }
            let target = entry == MountedTree.parentOfRoot ? MountedTree.root : entry
            results.u32(NFSStatus.ok)
            results.opaque(dispatcher.handles.handle(target))
            dispatcher.attributes.postOp(target, into: &results)
        } catch {
            results.u32(NFSStatus.of(error))
        }
        dispatcher.attributes.postOp(directory, into: &results)
    }

    /// Read, look up and execute are granted as far as the caller asked; modify, extend and delete never.
    private func access(_ id: UInt64, _ requested: UInt32, _ results: inout XDRWriter) {
        results.u32(NFSStatus.ok)
        dispatcher.attributes.postOp(id, into: &results)
        results.u32(requested & (0x01 | 0x02 | 0x20))
    }

    private func readlink(_ id: UInt64, _ results: inout XDRWriter) {
        answer(&results, failureAttributes: id) { (writer) throws(DiskError) in
            let target = try tree.fileSystem.readLink(tree.readerID(for: id))
            dispatcher.attributes.postOp(id, into: &writer)
            writer.opaque(target)
        }
    }

    private func read(_ id: UInt64, _ offset: UInt64, _ count: UInt32, _ results: inout XDRWriter) {
        answer(&results, failureAttributes: id) { (writer) throws(DiskError) in
            let reader = tree.readerID(for: id)
            let size = try tree.fileSystem.attributes(of: reader).size
            let bytes = try tree.fileSystem.read(reader, at: offset, count: Int(min(count, Self.maximumRead)))
            dispatcher.attributes.postOp(id, into: &writer)
            writer.u32(UInt32(bytes.count))
            writer.bool(offset + UInt64(bytes.count) >= size)
            writer.opaque(bytes)
        }
    }

    private func fsstat(_ id: UInt64, _ results: inout XDRWriter) {
        answer(&results, failureAttributes: id) { (writer) throws(DiskError) in
            let statistics = try tree.fileSystem.statistics()
            let block = UInt64(statistics.blockSize)
            dispatcher.attributes.postOp(id, into: &writer)
            writer.u64(statistics.totalBlocks * block)
            writer.u64(statistics.freeBlocks * block)
            writer.u64(statistics.freeBlocks * block)  // available: what FSKit reports too (df)
            writer.u64(statistics.files)
            writer.u64(0)
            writer.u64(0)
            writer.u32(0)  // invarsec
        }
    }

    private func fsinfo(_ id: UInt64, _ results: inout XDRWriter) {
        results.u32(NFSStatus.ok)
        dispatcher.attributes.postOp(id, into: &results)
        for value in [Self.maximumRead, 1 << 17, 4096, Self.maximumRead, 1 << 17, 4096, 1 << 16] { results.u32(value) }
        results.u64(UInt64.max >> 1)  // maxfilesize
        results.u32(0)  // time_delta: one nanosecond
        results.u32(1)
        results.u32(0x01 | 0x02 | 0x08)  // FSF3_LINK, FSF3_SYMLINK, FSF3_HOMOGENEOUS
    }

    private func pathconf(_ id: UInt64, _ results: inout XDRWriter) {
        let volume = tree.fileSystem.volume
        results.u32(NFSStatus.ok)
        dispatcher.attributes.postOp(id, into: &results)
        results.u32(65_000)
        results.u32(UInt32(volume.maximumNameLength))
        results.bool(true)  // no_trunc
        results.bool(true)  // chown_restricted
        results.bool(volume.caseRule == .insensitivePreserving)
        results.bool(true)  // case_preserving
    }
}
