import FSCore
import MountKit
import NFSProxy
import Testing

@Suite struct NFSDispatcherTests {
    static let export = NFSExport(token: Array(0 ..< 24))
    let dispatcher: NFSDispatcher
    let client = RPCClient()

    init() throws {
        dispatcher = NFSDispatcher(
            tree: try MountedTree(InMemoryFileSystem(root: 5, files: 10)),
            owner: (uid: 501, gid: 20),
            export: Self.export
        )
    }

    mutating func rootHandle() throws -> [UInt8] {
        let call = client.call(RPCClient.mount, 3, 1) { $0.string(Self.export.path) }
        var reply = try client.reply(dispatcher.handle(call))
        #expect(reply.acceptStatus == 0)
        #expect(try reply.results.u32() == 0, "MNT3_OK")
        return try reply.results.opaque(maximum: 64)
    }

    @Test mutating func nullAnswersBothPrograms() throws {
        #expect(try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 0))).acceptStatus == 0)
        #expect(try client.reply(dispatcher.handle(client.call(RPCClient.mount, 3, 0))).acceptStatus == 0)
    }

    @Test mutating func unknownProgramsVersionsAndProceduresAreRefusedByRPC() throws {
        #expect(try client.reply(dispatcher.handle(client.call(100_099, 3, 0))).acceptStatus == 1, "PROG_UNAVAIL")
        #expect(
            try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 4, 0))).acceptStatus == 2,
            "PROG_MISMATCH"
        )
        #expect(
            try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 99))).acceptStatus == 3,
            "PROC_UNAVAIL"
        )
        #expect(
            try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 1) { $0.u32(9) })).acceptStatus == 4,
            "GARBAGE_ARGS"
        )
        #expect(dispatcher.handle([1, 2, 3]) == nil, "not an RPC call: dropped")
    }

    @Test mutating func mountGivesTheRootAndGetattrDescribesIt() throws {
        let root = try rootHandle()
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 1) { $0.opaque(root) }))
        #expect(try reply.results.u32() == 0)
        let attributes = try Attributes(&reply.results)
        #expect(attributes.type == 2, "NF3DIR")
        #expect(attributes.fileID == 2, "the root is mount identifier 2")
    }

    /// The macOS NFS client passes names as Cocoa gave them, decomposed: they find the precomposed name stored (roadmap 0022).
    @Test mutating func aDecomposedNameFindsTheStoredOne() throws {
        var fileSystem = InMemoryFileSystem(root: 5, files: 0)
        fileSystem.nodes[5]?.children.append(("na\u{EF}ve.txt", 3000))
        fileSystem.nodes[3000] = InMemoryFileSystem.Node(
            attributes: NodeAttributes(id: 3000, parent: 5, kind: .regular)
        )
        let dispatcher = NFSDispatcher(
            tree: try MountedTree(fileSystem),
            owner: (uid: 501, gid: 20),
            export: Self.export
        )
        let call = client.call(RPCClient.mount, 3, 1) { $0.string(Self.export.path) }
        var mount = try client.reply(dispatcher.handle(call))
        _ = try mount.results.u32()
        let root = try mount.results.opaque(maximum: 64)
        var lookup = try client.reply(
            dispatcher.handle(
                client.call(RPCClient.nfs, 3, 3) {
                    $0.opaque(root)
                    $0.string("nai\u{308}ve.txt")
                }
            )
        )
        #expect(try lookup.results.u32() == 0, "NFS3_OK")
    }

    @Test mutating func lookupThenReadReturnsTheContentAndEOF() throws {
        let root = try rootHandle()
        var lookup = try client.reply(
            dispatcher.handle(
                client.call(RPCClient.nfs, 3, 3) {
                    $0.opaque(root)
                    $0.string("f3")
                }
            )
        )
        #expect(try lookup.results.u32() == 0)
        let file = try lookup.results.opaque(maximum: 64)
        var read = try client.reply(
            dispatcher.handle(
                client.call(RPCClient.nfs, 3, 6) {
                    $0.opaque(file)
                    $0.u64(2)
                    $0.u32(100)
                }
            )
        )
        #expect(try read.results.u32() == 0)
        if try read.results.bool() { _ = try Attributes(&read.results) }
        #expect(try read.results.u32() == 7, "count")
        #expect(try read.results.bool(), "eof")
        #expect(try read.results.opaque(maximum: 100) == Array("ntent 3".utf8))
    }

    @Test mutating func aMissingNameIsNoent() throws {
        let root = try rootHandle()
        var reply = try client.reply(
            dispatcher.handle(
                client.call(RPCClient.nfs, 3, 3) {
                    $0.opaque(root)
                    $0.string("nope")
                }
            )
        )
        #expect(try reply.results.u32() == 2, "NFS3ERR_NOENT")
    }

    @Test mutating func aHandleThatWasNeverIssuedIsBad() throws {
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 1) { $0.opaque([1, 2, 3]) }))
        #expect(try reply.results.u32() == 10_001, "NFS3ERR_BADHANDLE")
    }

    @Test(arguments: [UInt32(2), 7, 8, 9, 10, 11, 12, 13, 14, 15])
    mutating func everyMutationIsReadOnly(_ procedure: UInt32) throws {
        let root = try rootHandle()
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, procedure) { $0.opaque(root) }))
        #expect(reply.acceptStatus == 0)
        #expect(try reply.results.u32() == 30, "NFS3ERR_ROFS")
    }

    @Test mutating func readdirplusPagesThroughDotsAndEveryName() throws {
        let root = try rootHandle()
        var names: [String] = []
        var cookie: UInt64 = 0
        var verifier: UInt64 = 0
        var calls = 0
        while calls < 50 {
            calls += 1
            var reply = try client.reply(
                dispatcher.handle(
                    client.call(RPCClient.nfs, 3, 17) {
                        $0.opaque(root)
                        $0.u64(cookie)
                        $0.u64(verifier)
                        $0.u32(400)
                        $0.u32(600)
                    }
                )
            )
            #expect(try reply.results.u32() == 0)
            if try reply.results.bool() { _ = try Attributes(&reply.results) }
            verifier = try reply.results.u64()
            while try reply.results.bool() {
                _ = try reply.results.u64()  // fileid
                names.append(String(decoding: try reply.results.opaque(maximum: 255), as: UTF8.self))
                cookie = try reply.results.u64()
                if try reply.results.bool() { _ = try Attributes(&reply.results) }
                if try reply.results.bool() { _ = try reply.results.opaque(maximum: 64) }
            }
            if try reply.results.bool() { break }  // eof
        }
        #expect(names == [".", ".."] + (0 ..< 10).map { "f\($0)" })
        #expect(calls > 1, "a 600-byte limit must split the listing")
    }

    /// Free space reads as available, as the FSKit modules report it: `df` must not call a mounted volume full.
    @Test mutating func fsstatReportsFreeSpaceAsAvailable() throws {
        let root = try rootHandle()
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 18) { $0.opaque(root) }))
        #expect(try reply.results.u32() == 0)
        if try reply.results.bool() { _ = try Attributes(&reply.results) }
        #expect(try reply.results.u64() == 10 * 4096, "total")
        let free = try reply.results.u64()
        #expect(free == 5 * 4096)
        #expect(try reply.results.u64() == free, "available")
    }

    @Test mutating func fsinfoAdvertisesReadOnlyFriendlySizes() throws {
        let root = try rootHandle()
        var reply = try client.reply(dispatcher.handle(client.call(RPCClient.nfs, 3, 19) { $0.opaque(root) }))
        #expect(try reply.results.u32() == 0)
        if try reply.results.bool() { _ = try Attributes(&reply.results) }
        let readMax = try reply.results.u32()
        #expect(readMax >= 65_536)
    }
}
