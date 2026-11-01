import Darwin
import FSCore
import MountKit
import NFSProxy
import Testing

/// The server over a real loopback socket: one framed call, one framed reply, and nothing listening beyond 127.0.0.1.
@Suite struct LoopbackServerTests {
    static let export = NFSExport(token: Array(0 ..< 24))
    @Test func aFramedCallOverTCPGetsAFramedReply() throws {
        let dispatcher = NFSDispatcher(
            tree: try MountedTree(InMemoryFileSystem(root: 5, files: 1)),
            owner: (501, 20),
            export: Self.export
        )
        let server = try LoopbackServer(dispatcher: dispatcher, port: 0)
        defer { server.stop() }
        #expect(server.port > 0)

        let client = RPCClient()
        let call = client.call(RPCClient.nfs, 3, 0)
        let connection = try LoopbackClient(port: server.port)
        connection.send(call)
        var records = RecordReader(maximum: 1 << 20)
        let reply = connection.receive(&records)
        #expect(try client.reply(reply).acceptStatus == 0)
    }

    @Test func itListensOnLoopbackOnly() throws {
        let dispatcher = NFSDispatcher(
            tree: try MountedTree(InMemoryFileSystem(root: 5, files: 0)),
            owner: (501, 20),
            export: Self.export
        )
        let server = try LoopbackServer(dispatcher: dispatcher, port: 0)
        defer { server.stop() }
        #expect(server.address == "127.0.0.1")
    }
}
