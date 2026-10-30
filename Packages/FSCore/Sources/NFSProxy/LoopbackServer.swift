import Darwin
import Foundation
import Synchronization

/// Serves a dispatcher over TCP on 127.0.0.1 only, one thread per connection. Nothing off this Mac can reach it.
public final class LoopbackServer: Sendable {
    public struct Failure: Error, Equatable {
        public let call: String
        public let errno: Int32
    }

    public let address = "127.0.0.1"
    public let port: UInt16
    private let listener: Int32
    private let dispatcher: NFSDispatcher
    private let connections = Mutex<Set<Int32>>([])
    private let stopped = Atomic<Bool>(false)

    /// Listens on `port` (0 asks the system for a free one) and starts accepting.
    public init(dispatcher: NFSDispatcher, port: UInt16) throws(Failure) {
        self.dispatcher = dispatcher
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

    private func acceptLoop() {
        while !stopped.load(ordering: .acquiring) {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                return
            }
            connections.withLock { _ = $0.insert(connection) }
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    /// Reads records, answers each in order, and closes on end of stream, an error, or an oversized record.
    private func serve(_ connection: Int32) {
        defer {
            connections.withLock { _ = $0.remove(connection) }
            close(connection)
        }
        var records = RecordReader(maximum: 2 << 20)
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { unsafe read(connection, $0.baseAddress, $0.count) }
            guard count > 0 else { return }
            records.append(Array(buffer[0 ..< count]))
            while true {
                let record: [UInt8]?
                do throws(XDRError) { record = try records.next() } catch { return }  // oversized: drop the connection
                guard let call = record else { break }
                guard let reply = dispatcher.handle(call) else { continue }
                guard send(RecordReader.frame(reply), to: connection) else { return }
            }
        }
    }

    private func send(_ bytes: [UInt8], to connection: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return unsafe write(connection, base + sent, raw.count - sent)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}
