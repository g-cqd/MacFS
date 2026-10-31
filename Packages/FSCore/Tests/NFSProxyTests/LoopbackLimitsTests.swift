import Darwin
import Foundation
import NFSProxy
import Testing

/// What a connection may cost (roadmap 0038, after Everest's WebDAV server: an idle timeout, a write abandoned without progress,
/// and requests that do not wait behind one slow one): a cap on connections, a client that says nothing or stops reading is
/// dropped after a bounded time, and the calls of one connection are answered concurrently, each reply whole.
@Suite(.serialized) struct LoopbackLimitsTests {
    static func limits(
        connections: Int = 8, idle: Duration = .seconds(30), stalled: Duration = .seconds(30), concurrentCalls: Int = 4
    ) -> LoopbackServer.Limits {
        LoopbackServer.Limits(connections: connections, idle: idle, stalled: stalled, concurrentCalls: concurrentCalls)
    }

    /// Echoes each record (its first four bytes play the xid).
    static let echo: @Sendable ([UInt8]) -> [UInt8]? = { $0 }

    @Test func aSilentClientIsDroppedAfterTheIdleTimeout() throws {
        let server = try LoopbackServer(port: 0, limits: Self.limits(idle: .milliseconds(200)), handle: Self.echo)
        defer { server.stop() }
        let client = try LoopbackClient(port: server.port)
        let start = ContinuousClock.now
        #expect(client.closedByServer())
        #expect(ContinuousClock.now - start < .seconds(3))
        #expect(server.counts().idle == 1)
    }

    @Test func connectionsBeyondTheCapAreRefused() throws {
        let server = try LoopbackServer(port: 0, limits: Self.limits(connections: 2), handle: Self.echo)
        defer { server.stop() }
        let (first, second) = (try LoopbackClient(port: server.port), try LoopbackClient(port: server.port))
        var records = RecordReader(maximum: 1 << 20)
        first.send([0, 0, 0, 1])
        #expect(first.receive(&records) == [0, 0, 0, 1], "the first is served before the third arrives")
        let third = try LoopbackClient(port: server.port)
        #expect(third.closedByServer())
        #expect(server.counts().refused == 1)
        #expect(server.counts().accepted == 2)
        second.send([0, 0, 0, 2])
        #expect(second.receive(&records) == [0, 0, 0, 2], "the others are still served")
    }

    @Test func aClientThatStopsReadingIsDropped() throws {
        let big = [UInt8](repeating: 7, count: 256 << 10)
        let server = try LoopbackServer(
            port: 0, limits: Self.limits(stalled: .milliseconds(200)), handle: { _ in big })
        defer { server.stop() }
        let client = try LoopbackClient(port: server.port, receiveBuffer: 4_096)
        for xid in 0 ..< 40 { client.send([0, 0, 0, UInt8(xid)]) }
        let deadline = ContinuousClock.now + .seconds(5)
        while server.counts().stalled == 0, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(server.counts().stalled == 1)
        #expect(client.closedByServer())
    }

    /// ADR-0014's numbers.
    @Test func theStandardLimitsAreADR0014s() {
        #expect(
            LoopbackServer.Limits.standard
                == Self.limits(connections: 16, idle: .seconds(300), stalled: .seconds(30), concurrentCalls: 8))
    }

    @Test func aClosedConnectionFreesItsPlace() throws {
        let server = try LoopbackServer(port: 0, limits: Self.limits(connections: 1), handle: Self.echo)
        defer { server.stop() }
        var records = RecordReader(maximum: 1 << 20)
        do {
            let first = try LoopbackClient(port: server.port)
            first.send([0, 0, 0, 1])
            #expect(first.receive(&records) == [0, 0, 0, 1])
        }
        let deadline = ContinuousClock.now + .seconds(3)
        var served = false
        while !served, ContinuousClock.now < deadline {
            let next = try LoopbackClient(port: server.port)
            next.send([0, 0, 0, 2])
            served = next.receive(&records) == [0, 0, 0, 2]
        }
        #expect(served, "the place of a client that hung up is given to the next")
    }

    @Test func aStoppedServerAcceptsNothing() throws {
        let server = try LoopbackServer(port: 0, limits: Self.limits(), handle: Self.echo)
        server.stop()
        #expect(LoopbackClient.connect(port: server.port) == nil, "the listener is closed")
    }

    /// A client that hangs up while its reply is being written costs the server nothing: no SIGPIPE (which would end this
    /// process), and the server goes on serving.
    @Test func aClientThatHangsUpMidReplyIsHarmless() throws {
        let big = [UInt8](repeating: 3, count: 4 << 20)
        let server = try LoopbackServer(port: 0, limits: Self.limits(), handle: { _ in big })
        defer { server.stop() }
        for _ in 0 ..< 4 {
            let client = try LoopbackClient(port: server.port, receiveBuffer: 4_096)
            for xid in 0 ..< 4 { client.send([0, 0, 0, UInt8(xid)]) }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let client = try LoopbackClient(port: server.port)
        var records = RecordReader(maximum: 8 << 20)
        client.send([0, 0, 0, 9])
        #expect(client.receive(&records)?.count == big.count)
        #expect(server.counts().stalled == 0, "a hang-up is not a stall")
        #expect(server.counts().idle == 0, "nor silence")
    }

    /// A client that resets its connection (a close with unread data, or linger zero) ended it; it was not silent.
    @Test func aResetIsNotSilence() throws {
        let server = try LoopbackServer(port: 0, limits: Self.limits(), handle: Self.echo)
        defer { server.stop() }
        do {
            let client = try LoopbackClient(port: server.port)
            var records = RecordReader(maximum: 1 << 20)
            client.send([0, 0, 0, 1])
            #expect(client.receive(&records) == [0, 0, 0, 1])
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(client.socket, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        Thread.sleep(forTimeInterval: 0.3)  // the reader sees the reset
        #expect(server.counts().idle == 0)
    }

    /// A reader that pauses longer than `stalled` but less than twice it receives every byte in order. The kernel's send
    /// timeout runs per wait, not per call: the write that was waiting returns the part it sent, and the next resumes where it
    /// stopped. A write that makes no progress at all for `stalled` is what drops a client.
    @Test func aPausingReaderGetsEveryByte() throws {
        let big = (0 ..< (1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) }
        let server = try LoopbackServer(port: 0, limits: Self.limits(stalled: .milliseconds(300)), handle: { _ in big })
        defer { server.stop() }
        let client = try LoopbackClient(port: server.port, receiveBuffer: 8_192)
        client.send([0, 0, 0, 1])
        var records = RecordReader(maximum: 4 << 20)
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        var reply: [UInt8]?
        var received = 0
        func drain() {
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    recv(client.socket, $0.baseAddress, $0.count, MSG_DONTWAIT)
                }
                guard count > 0 else { return }
                received += count
                records.append(Array(buffer[0 ..< count]))
            }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while reply == nil, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.45)
            drain()
            reply = try records.next()
        }
        Thread.sleep(forTimeInterval: 0.3)
        drain()
        #expect(reply == big, "\(reply?.count ?? 0) bytes")
        #expect(received == 4 + big.count, "the reply and nothing after it")
        #expect(server.counts().stalled == 0)
    }

    /// TCP may deliver a record a byte at a time; each short read is data, not the end of the stream.
    @Test func aRecordArrivingAByteAtATimeIsAnswered() throws {
        let server = try LoopbackServer(port: 0, limits: Self.limits(), handle: Self.echo)
        defer { server.stop() }
        let client = try LoopbackClient(port: server.port)
        var yes: Int32 = 1
        _ = setsockopt(client.socket, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        for byte in RecordReader.frame([0, 0, 0, 5, 6, 7, 8]) {
            _ = [byte].withUnsafeBytes { write(client.socket, $0.baseAddress, 1) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        var records = RecordReader(maximum: 1 << 20)
        #expect(client.receive(&records) == [0, 0, 0, 5, 6, 7, 8])
    }

    /// Records up to 2 MiB are served (ADR-0010); a longer one drops the connection.
    @Test func recordsAreBoundedAtTwoMebibytes() throws {
        let server = try LoopbackServer(
            port: 0, limits: Self.limits(), handle: { $0.prefix(4) + [UInt8(truncatingIfNeeded: $0.count >> 20)] })
        defer { server.stop() }
        var records = RecordReader(maximum: 1 << 20)
        let fits = try LoopbackClient(port: server.port)
        fits.send([UInt8](repeating: 1, count: 2 << 20))
        #expect(fits.receive(&records) == [1, 1, 1, 1, 2])
        let tooLong = try LoopbackClient(port: server.port)
        tooLong.send([UInt8](repeating: 1, count: (2 << 20) + 4))
        #expect(tooLong.closedByServer())
    }

    @Test func aSlowCallDoesNotHoldBackTheNextOne() throws {
        let server = try LoopbackServer(
            port: 0, limits: Self.limits(),
            handle: { record in
                if record.first == 1 { Thread.sleep(forTimeInterval: 0.5) }
                return record
            })
        defer { server.stop() }
        let client = try LoopbackClient(port: server.port)
        var records = RecordReader(maximum: 1 << 20)
        client.send([1, 0, 0, 0])
        client.send([2, 0, 0, 0])
        #expect(client.receive(&records) == [2, 0, 0, 0], "the quick call answered first")
        #expect(client.receive(&records) == [1, 0, 0, 0])
    }

    @Test func manyConcurrentRepliesArriveWhole() throws {
        let server = try LoopbackServer(
            port: 0, limits: Self.limits(concurrentCalls: 8),
            handle: { record in
                [UInt8](repeating: record[0], count: 100_000 + Int(record[0]) * 1_000)
            })
        defer { server.stop() }
        let client = try LoopbackClient(port: server.port)
        var records = RecordReader(maximum: 1 << 20)
        for xid in 0 ..< 32 { client.send([UInt8(xid), 0, 0, 0]) }
        var seen: Set<UInt8> = []
        for _ in 0 ..< 32 {
            let reply = try #require(client.receive(&records))
            let first = try #require(reply.first)
            #expect(reply.count == 100_000 + Int(first) * 1_000 && reply.allSatisfy { $0 == first }, "reply \(first)")
            seen.insert(first)
        }
        #expect(seen.count == 32)
    }
}
