import NFSProxy

/// Builds ONC RPC calls and reads replies, so tests speak to the dispatcher as a client would.
/// A class: `client.reply(handle(client.call(…)))` must see the transaction id `call` just advanced, and a
/// struct receiver is copied before its argument runs.
final class RPCClient {
    static let nfs: UInt32 = 100_003
    static let mount: UInt32 = 100_005

    struct Reply {
        let acceptStatus: UInt32
        var results: XDRReader
    }

    var xid: UInt32 = 0x1000

    func call(
        _ program: UInt32,
        _ version: UInt32 = 3,
        _ procedure: UInt32,
        _ arguments: (inout XDRWriter) -> Void = { _ in }
    )
        -> [UInt8]
    {
        xid += 1
        var writer = XDRWriter()
        writer.u32(xid)
        writer.u32(0)  // CALL
        writer.u32(2)  // RPC version
        writer.u32(program)
        writer.u32(version)
        writer.u32(procedure)
        // AUTH_UNIX credentials: stamp, machine name, uid, gid, no groups.
        var auth = XDRWriter()
        auth.u32(0)
        auth.string("test")
        auth.u32(501)
        auth.u32(20)
        auth.u32(0)
        writer.u32(1)
        writer.opaque(auth.bytes)
        writer.u32(0)  // verifier AUTH_NONE
        writer.u32(0)
        arguments(&writer)
        return writer.bytes
    }

    func reply(_ bytes: [UInt8]?) throws -> Reply {
        guard let bytes else { throw XDRError.truncated }
        var reader = XDRReader(bytes)
        guard try reader.u32() == xid, try reader.u32() == 1, try reader.u32() == 0 else { throw XDRError.truncated }
        _ = try reader.u32()  // verifier flavor
        _ = try reader.opaque(maximum: 400)
        return Reply(acceptStatus: try reader.u32(), results: reader)
    }
}

/// The parts of an NFSv3 `fattr3` the tests check.
struct Attributes {
    let type: UInt32
    let mode: UInt32
    let size: UInt64
    let fileID: UInt64

    init(_ reader: inout XDRReader) throws {
        type = try reader.u32()
        mode = try reader.u32()
        _ = try reader.u32()  // nlink
        _ = try reader.u32()  // uid
        _ = try reader.u32()  // gid
        size = try reader.u64()
        _ = try reader.u64()  // used
        _ = try reader.u64()  // rdev
        _ = try reader.u64()  // fsid
        fileID = try reader.u64()
        for _ in 0 ..< 6 { _ = try reader.u32() }  // atime, mtime, ctime
    }
}
