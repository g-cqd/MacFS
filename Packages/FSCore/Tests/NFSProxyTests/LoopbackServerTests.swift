import Darwin
import FSCore
import MountKit
import NFSProxy
import Testing

/// The server over a real loopback socket: one framed call, one framed reply, and nothing listening beyond 127.0.0.1.
@Suite struct LoopbackServerTests {
    @Test func aFramedCallOverTCPGetsAFramedReply() throws {
        let dispatcher = NFSDispatcher(tree: try MountedTree(InMemoryFileSystem(root: 5, files: 1)), owner: (501, 20))
        let server = try LoopbackServer(dispatcher: dispatcher, port: 0)
        defer { server.stop() }
        #expect(server.port > 0)

        let client = RPCClient()
        let call = client.call(RPCClient.nfs, 3, 0)
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(server.port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0)
        let framed = RecordReader.frame(call)
        #expect(framed.withUnsafeBytes { write(socketFD, $0.baseAddress, $0.count) } == framed.count)

        var records = RecordReader(maximum: 1 << 20)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var reply: [UInt8]?
        for _ in 0 ..< 100 where reply == nil {
            let count = buffer.withUnsafeMutableBytes { read(socketFD, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            records.append(Array(buffer[0 ..< count]))
            reply = try records.next()
        }
        #expect(try client.reply(reply).acceptStatus == 0)
    }

    @Test func itListensOnLoopbackOnly() throws {
        let dispatcher = NFSDispatcher(tree: try MountedTree(InMemoryFileSystem(root: 5, files: 0)), owner: (501, 20))
        let server = try LoopbackServer(dispatcher: dispatcher, port: 0)
        defer { server.stop() }
        #expect(server.address == "127.0.0.1")
    }
}
