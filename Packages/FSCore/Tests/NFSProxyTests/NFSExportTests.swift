import FSCore
import MountKit
import NFSProxy
import Testing

/// The export is a capability (roadmap 0038): an unguessable path that admits one MNT, and handles that carry a secret. The mount
/// table shows every mount's source to every local user, so the path stops being secret once mounted; the single MNT and the
/// handles' secret are what keep another local process out.
@Suite struct NFSExportTests {
    static let token: [UInt8] = Array(0 ..< 24)
    let export = NFSExport(token: Self.token)
    let client = RPCClient()

    func dispatcher() throws -> NFSDispatcher {
        NFSDispatcher(tree: try MountedTree(InMemoryFileSystem(root: 5, files: 3)), owner: (501, 20), export: export)
    }

    /// MNT of `path`: the status, and the handle when it is MNT3_OK.
    func mount(_ path: String, on dispatcher: NFSDispatcher) throws -> (status: UInt32, handle: [UInt8]?) {
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.mount, 3, 1) { $0.string(path) }))
        #expect(reply.acceptStatus == 0)
        let status = try reply.results.u32()
        return (status, status == 0 ? try reply.results.opaque(maximum: 64) : nil)
    }

    @Test func theExportPathIsTheTokenInHex() {
        #expect(export.path == "/macfs-000102030405060708090a0b0c0d0e0f")
        #expect(
            NFSExport(token: Array(repeating: 0xAB, count: 24)).path == "/macfs-" + String(repeating: "ab", count: 16))
        #expect(NFSExport.random().path != NFSExport.random().path)
        #expect(NFSExport.random().path.count == export.path.count)
    }

    @Test func onlyTheExportPathMounts() throws {
        let dispatcher = try dispatcher()
        for path in ["/", "", "/macfs-000102030405060708090a0b0c0d0e0e", export.path + "/"] {
            #expect(try mount(path, on: dispatcher).status == 2, "MNT3ERR_NOENT for \(path.debugDescription)")
        }
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.mount, 3, 1) { $0.string(export.path) }))
        #expect(try reply.results.u32() == 0)
        _ = try reply.results.opaque(maximum: 64)
        #expect(try reply.results.u32() == 1, "one auth flavor")
        #expect(try reply.results.u32() == 1, "AUTH_UNIX, which mount_nfs sends")
    }

    @Test func theExportAdmitsOneMount() throws {
        let dispatcher = try dispatcher()
        #expect(try mount(export.path, on: dispatcher).status == 0)
        #expect(
            try mount(export.path, on: dispatcher).status == 13, "MNT3ERR_ACCES: the path is in the mount table now")
    }

    /// DUMP and UMNTALL take no arguments, UMNT a path; MNT and UMNT paths are at most MNTPATHLEN, 1,024 bytes (RFC 1813).
    @Test func mountProceduresReadTheirArgumentsAndNoMore() throws {
        let dispatcher = try dispatcher()
        for procedure: UInt32 in [2, 4] {
            #expect(try client.reply(dispatcher.handle(client.call(RPCClient.mount, 3, procedure))).acceptStatus == 0)
        }
        for (procedure, length, status) in [(UInt32(1), 1_024, 0), (1, 1_025, 4), (3, 1_024, 0), (3, 1_025, 4)] {
            let path = "/" + String(repeating: "a", count: length - 1)
            let reply = try client.reply(
                dispatcher.handle(client.call(RPCClient.mount, 3, procedure) { $0.string(path) }))
            #expect(reply.acceptStatus == UInt32(status), "procedure \(procedure), \(length) bytes")
        }
    }

    @Test func theExportListShowsNothing() throws {
        var reply = try client.reply(try dispatcher().handle(client.call(RPCClient.mount, 3, 5)))
        #expect(reply.acceptStatus == 0)
        #expect(try reply.results.bool() == false, "no exports listed")
    }

    /// A handle is refused unless it carries the export's secret: a process that skips MNT cannot build one from the volume's UUID.
    @Test func handlesCarryTheExportsSecret() throws {
        let dispatcher = try dispatcher()
        let root = try #require(try mount(export.path, on: dispatcher).handle)
        func getattr(_ handle: [UInt8]) throws -> UInt32 {
            var reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 1) { $0.opaque(handle) }))
            return try reply.results.u32()
        }
        #expect(try getattr(root) == 0)
        #expect(root.count == 24, "MFS3, 4 bytes of volume, 8 of secret, 8 of mount identifier")
        for index in 0 ..< 16 {  // the identifier's own bytes name other nodes, not forgeries
            var forged = root
            forged[index] ^= 1
            #expect(try getattr(forged) == 10_001, "NFS3ERR_BADHANDLE with byte \(index) changed")
        }
        let other = NFSDispatcher(
            tree: try MountedTree(InMemoryFileSystem(root: 5, files: 3)), owner: (501, 20),
            export: NFSExport(token: Self.token.map { $0 ^ 0xFF }))
        var reply = try client.reply(other.handle(client.call(RPCClient.nfs, 3, 1) { $0.opaque(root) }))
        #expect(try reply.results.u32() == 10_001, "another export's handle")
    }
}
