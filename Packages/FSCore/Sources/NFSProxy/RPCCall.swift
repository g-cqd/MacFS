/// The header of an ONC RPC call (RFC 5531): who is asked what. Credentials are read and ignored: the
/// export is read-only and the same for every caller.
struct RPCCall: Sendable {
    let xid: UInt32
    let program: UInt32
    let version: UInt32
    let procedure: UInt32

    /// Parses the header and leaves `reader` at the arguments; nil when the bytes are not a call at all.
    init?(_ reader: inout XDRReader) {
        guard let xid = try? reader.u32(), (try? reader.u32()) == 0, (try? reader.u32()) == 2,
            let program = try? reader.u32(), let version = try? reader.u32(), let procedure = try? reader.u32(),
            (try? reader.u32()) != nil, (try? reader.opaque(maximum: 400)) != nil,
            (try? reader.u32()) != nil, (try? reader.opaque(maximum: 400)) != nil
        else { return nil }
        self.xid = xid
        self.program = program
        self.version = version
        self.procedure = procedure
    }

    /// An accepted reply: `status` 0 (success, then `results`), 1 to 4 (the RPC-level refusals).
    func reply(status: UInt32, results: XDRWriter = XDRWriter()) -> [UInt8] {
        var writer = XDRWriter()
        writer.u32(xid)
        writer.u32(1)  // REPLY
        writer.u32(0)  // MSG_ACCEPTED
        writer.u32(0)  // verifier AUTH_NONE
        writer.u32(0)
        writer.u32(status)
        if status == 2 {  // PROG_MISMATCH: the versions supported
            writer.u32(3)
            writer.u32(3)
        }
        writer.append(results)
        return writer.bytes
    }
}
