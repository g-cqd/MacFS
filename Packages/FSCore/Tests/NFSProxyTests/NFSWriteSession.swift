import CrashTesting
import ExtFS
import FSCore
import Foundation
import MountKit
import NFSProxy
import Testing

/// A writable NFS export of a copy of the ext2 test image, spoken to as a client would (RFC 1813's argument and reply layouts).
/// Each change returns its status, and what its reply carried that the tests read.
final class NFSWriteSession {
    static let export = NFSExport(token: Array(0 ..< 24))
    static let images = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("TestImages")

    let device: MemoryBlockSource
    let volume: ExtFileSystem
    let dispatcher: NFSDispatcher
    let client = RPCClient()
    private(set) var root: [UInt8] = []

    /// Read-only when `writable` is false: the same export without a writer.
    init(writable: Bool = true) throws {
        let image = try FileBlockSource(path: Self.images.appendingPathComponent("ext2.img").path)
        device = MemoryBlockSource(try image.read(at: 0, count: Int(image.byteCount)))
        volume = writable ? try ExtFileSystem(writable: device, clock: { .now }) : try ExtFileSystem(source: device)
        dispatcher = NFSDispatcher(
            tree: try MountedTree(volume),
            owner: (uid: 501, gid: 20),
            export: Self.export,
            writer: writable ? volume : nil
        )
        var reply = try client.reply(
            dispatcher.handle(client.call(RPCClient.mount, 3, 1) { $0.string(Self.export.path) })
        )
        #expect(try reply.results.u32() == 0)
        root = try reply.results.opaque(maximum: 64)
    }

    func call(_ procedure: UInt32, _ arguments: (inout XDRWriter) -> Void) throws -> XDRReader {
        let reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, procedure, arguments)))
        #expect(reply.acceptStatus == 0, "procedure \(procedure) accepted")
        return reply.results
    }

    /// `wcc_data`: an optional `wcc_attr`, then an optional `fattr3`.
    static func skipWcc(_ reader: inout XDRReader) throws {
        if try reader.bool() { for _ in 0 ..< 6 { _ = try reader.u32() } }
        try skipPostOp(&reader)
    }

    static func skipPostOp(_ reader: inout XDRReader) throws {
        if try reader.bool() { _ = try Attributes(&reader) }
    }

    /// `sattr3` with only what is given.
    static func sattr(_ writer: inout XDRWriter, mode: UInt32? = nil, size: UInt64? = nil, mtime: UInt32? = nil) {
        writer.bool(mode != nil)
        if let mode { writer.u32(mode) }
        writer.bool(false)  // uid
        writer.bool(false)  // gid
        writer.bool(size != nil)
        if let size { writer.u64(size) }
        writer.u32(0)  // atime: don't change
        if let mtime {
            writer.u32(2)  // set to client time
            writer.u32(mtime)
            writer.u32(0)
        } else {
            writer.u32(0)
        }
    }

    func lookup(_ name: String, in directory: [UInt8]? = nil) throws -> (status: UInt32, handle: [UInt8]?) {
        var results = try call(3) {
            $0.opaque(directory ?? root)
            $0.string(name)
        }
        let status = try results.u32()
        return (status, status == 0 ? try results.opaque(maximum: 64) : nil)
    }

    func getattr(_ handle: [UInt8]) throws -> Attributes {
        var results = try call(1) { $0.opaque(handle) }
        #expect(try results.u32() == 0)
        return try Attributes(&results)
    }

    /// CREATE, MKDIR or SYMLINK's reply: the status and the new handle.
    static func made(_ results: inout XDRReader) throws -> (status: UInt32, handle: [UInt8]?) {
        let status = try results.u32()
        guard status == 0 else { return (status, nil) }
        let handle = try results.bool() ? try results.opaque(maximum: 64) : nil
        return (status, handle)
    }

    /// CREATE: `how` 0 unchecked, 1 guarded (with `mode`, `size`), 2 exclusive (with `verifier`).
    func create(_ name: String, how: UInt32, mode: UInt32 = 0o644, size: UInt64? = nil, verifier: [UInt8] = [])
        throws -> (status: UInt32, handle: [UInt8]?)
    {
        var results = try call(8) {
            $0.opaque(self.root)
            $0.string(name)
            $0.u32(how)
            if how == 2 { $0.fixed(verifier) } else { Self.sattr(&$0, mode: mode, size: size) }
        }
        return try Self.made(&results)
    }

    func mkdir(_ name: String, in directory: [UInt8]? = nil) throws -> (status: UInt32, handle: [UInt8]?) {
        var results = try call(9) {
            $0.opaque(directory ?? self.root)
            $0.string(name)
            Self.sattr(&$0, mode: 0o750)
        }
        return try Self.made(&results)
    }

    func symlink(_ name: String, to target: String) throws -> (status: UInt32, handle: [UInt8]?) {
        var results = try call(10) {
            $0.opaque(self.root)
            $0.string(name)
            Self.sattr(&$0)
            $0.string(target)
        }
        return try Self.made(&results)
    }

    /// WRITE: the status, the count written, how it was committed, and the write verifier.
    func write(_ handle: [UInt8], at offset: UInt64, _ bytes: [UInt8], stable: UInt32)
        throws -> (status: UInt32, count: UInt32, committed: UInt32, verifier: [UInt8])
    {
        var results = try call(7) {
            $0.opaque(handle)
            $0.u64(offset)
            $0.u32(UInt32(bytes.count))
            $0.u32(stable)
            $0.opaque(bytes)
        }
        let status = try results.u32()
        try Self.skipWcc(&results)
        guard status == 0 else { return (status, 0, 0, []) }
        return (status, try results.u32(), try results.u32(), try results.fixed(8))
    }

    func read(_ handle: [UInt8], at offset: UInt64, count: UInt32) throws -> [UInt8] {
        var results = try call(6) {
            $0.opaque(handle)
            $0.u64(offset)
            $0.u32(count)
        }
        #expect(try results.u32() == 0)
        try Self.skipPostOp(&results)
        _ = try results.u32()
        _ = try results.bool()
        return try results.opaque(maximum: 1 << 20)
    }

    /// A procedure whose reply starts with its status, which is all that is read.
    func status(_ procedure: UInt32, _ arguments: (inout XDRWriter) -> Void) throws -> UInt32 {
        var results = try call(procedure, arguments)
        return try results.u32()
    }
}
