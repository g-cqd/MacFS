import Darwin
import Dispatch
import Foundation
import Synchronization

/// Serves RPC records over TCP on 127.0.0.1 only: nothing off this Mac can reach it. Each connection has a reader thread; its
/// calls are answered concurrently, a bounded number at a time, each reply written whole (ONC RPC matches replies by xid), so a
/// large READ does not hold back the LOOKUPs behind it. What a connection may cost is bounded (roadmap 0038, after Everest's
/// WebDAV server): connections beyond a cap are refused, a client silent for `idle` or not reading for `stalled` is dropped.
public final class LoopbackServer: Sendable {
    public struct Failure: Error, Equatable {
        public let call: String
        public let errno: Int32
    }

    public struct Limits: Sendable, Equatable {
        public var connections: Int
        public var idle: Duration
        public var stalled: Duration
        public var concurrentCalls: Int

        public init(connections: Int, idle: Duration, stalled: Duration, concurrentCalls: Int) {
            self.connections = connections
            self.idle = idle
            self.stalled = stalled
            self.concurrentCalls = concurrentCalls
        }

        /// macOS's client holds one connection per mount and reconnects after a drop; it reads ahead 16 calls by default;
        /// Everest abandons a write after 30 s without progress.
        public static let standard = Limits(
            connections: 16,
            idle: .seconds(300),
            stalled: .seconds(30),
            concurrentCalls: 8
        )
    }

    /// Connections served, refused at the cap, dropped silent, dropped not reading.
    public struct Counts: Sendable, Equatable {
        public let accepted: Int
        public let refused: Int
        public let idle: Int
        public let stalled: Int
    }

    public let address = "127.0.0.1"
    public let port: UInt16
    private let listener: Int32
    private let handle: @Sendable ([UInt8]) -> [UInt8]?
    private let limits: Limits
    private let connections = Mutex<Set<Int32>>([])
    private let stopped = Atomic<Bool>(false)
    private let accepted = Atomic<Int>(0)
    private let refused = Atomic<Int>(0)
    private let idled = Atomic<Int>(0)
    private let stalled = Atomic<Int>(0)
    private let calls = DispatchQueue(label: "macfs.nfsproxy.calls", attributes: .concurrent)

    /// Serves `dispatcher` on `port` (0 asks the system for a free one).
    public convenience init(dispatcher: NFSDispatcher, port: UInt16, limits: Limits = .standard) throws(Failure) {
        try self.init(port: port, limits: limits, handle: dispatcher.handle)
    }

    /// Serves `handle`: one record in, one reply out, nil for none.
    public init(port: UInt16, limits: Limits, handle: @escaping @Sendable ([UInt8]) -> [UInt8]?) throws(Failure) {
        self.handle = handle
        self.limits = limits
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(call: "socket", errno: errno) }
        var yes: Int32 = 1
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(port).bigEndian
        local.sin_addr.s_addr = in_addr_t(0x7F00_0001).bigEndian  // 127.0.0.1
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &local) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let failure = Failure(call: "bind/listen", errno: errno)
            close(fd)
            throw failure
        }
        var length = size
        _ = withUnsafeMutablePointer(to: &local) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { unsafe getsockname(fd, $0, &length) }
        }
        self.port = UInt16(bigEndian: local.sin_port)
        self.listener = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    public func stop() {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return }
        close(listener)
        for connection in connections.withLock({ $0 }) { shutdown(connection, SHUT_RDWR) }
    }

    public func counts() -> Counts {
        Counts(
            accepted: accepted.load(ordering: .relaxed),
            refused: refused.load(ordering: .relaxed),
            idle: idled.load(ordering: .relaxed),
            stalled: stalled.load(ordering: .relaxed)
        )
    }

    private func acceptLoop() {
        while !stopped.load(ordering: .acquiring) {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            let admitted = connections.withLock { open in
                guard open.count < limits.connections else { return false }
                open.insert(connection)
                return true
            }
            guard admitted else {
                refused.add(1, ordering: .relaxed)
                close(connection)
                continue
            }
            accepted.add(1, ordering: .relaxed)
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    /// Reads records and hands each call to the pool; ends on end of stream, silence, an oversized record or a failed write.
    /// The descriptor is closed only once every call in flight has finished, so a late reply cannot reach a reused descriptor.
    private func serve(_ connection: Int32) {
        Self.configure(connection, limits)
        let inFlight = DispatchGroup()
        let slots = DispatchSemaphore(value: limits.concurrentCalls)
        let writer = Writer(connection)
        defer {
            shutdown(connection, SHUT_RDWR)
            inFlight.wait()
            connections.withLock { _ = $0.remove(connection) }
            close(connection)
        }
        var records = RecordReader(maximum: 2 << 20)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { unsafe read(connection, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                idled.add(1, ordering: .relaxed)
                return
            }
            guard count > 0 else { return }
            records.append(Array(buffer[0 ..< count]))
            while true {
                let record: [UInt8]?
                do throws(XDRError) { record = try records.next() } catch { return }  // oversized: drop the connection
                guard let call = record else { break }
                slots.wait()  // at most `concurrentCalls` in flight: past that, stop reading
                inFlight.enter()
                calls.async { [self] in
                    defer {
                        slots.signal()
                        inFlight.leave()
                    }
                    guard let reply = handle(call) else { return }
                    self.reply(RecordReader.frame(reply), writer)
                }
            }
        }
    }

    /// One connection's writes, one at a time, and whether one has failed (the connection is then finished).
    private final class Writer: Sendable {
        let connection: Int32
        let failed = Mutex(false)

        init(_ connection: Int32) { self.connection = connection }
    }

    /// Writes one framed reply whole; a write that makes no progress for `stalled` finishes the connection.
    private func reply(_ bytes: [UInt8], _ writer: Writer) {
        let connection = writer.connection
        writer.failed.withLock { failed in
            guard !failed else { return }
            switch Self.send(bytes, to: connection) {
                case .sent: return
                case .stalled: stalled.add(1, ordering: .relaxed)
                case .closed: break
            }
            failed = true
            shutdown(connection, SHUT_RDWR)  // ends the reader, which closes once the other calls are done
        }
    }

    private enum Sent { case sent, stalled, closed }

    private static func send(_ bytes: [UInt8], to connection: Int32) -> Sent {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return unsafe write(connection, base + sent, raw.count - sent)
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .stalled }
            guard count > 0 else { return .closed }
            sent += count
        }
        return .sent
    }

    /// Receive and send timeouts from the limits, and no SIGPIPE when a client has gone.
    private static func configure(_ connection: Int32, _ limits: Limits) {
        var receive = timeval(limits.idle)
        var send = timeval(limits.stalled)
        var yes: Int32 = 1
        let timeSize = socklen_t(MemoryLayout<timeval>.size)
        _ = unsafe setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &receive, timeSize)
        _ = unsafe setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &send, timeSize)
        _ = unsafe setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
}

extension timeval {
    init(_ duration: Duration) {
        let (seconds, attoseconds) = duration.components
        self.init(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
    }
}
