import Darwin
import NFSProxy
import Testing

/// A client of `LoopbackServer`: a connected socket, closed on deinit, that frames calls and reads records.
final class LoopbackClient {
    let socket: Int32

    /// A socket connected to 127.0.0.1:`port`, or nil when nothing listens. No SIGPIPE: a server that closes first must not
    /// end the test process. The receive buffer, when given, is set before connecting, where it bounds the window.
    static func connect(port: UInt16, receiveBuffer: Int32? = nil) -> Int32? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        if var size = receiveBuffer {
            _ = setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(socket)
            return nil
        }
        return socket
    }

    init(port: UInt16, receiveBuffer: Int32? = nil) throws {
        socket = try #require(Self.connect(port: port, receiveBuffer: receiveBuffer))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { close(socket) }

    func send(_ record: [UInt8]) {
        let framed = RecordReader.frame(record)
        _ = framed.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
    }

    /// The next record, or nil when the server closed the connection (or 5 s passed).
    func receive(_ records: inout RecordReader) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if let record = try? records.next() { return record }
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            guard count > 0 else { return nil }
            records.append(Array(buffer[0 ..< count]))
        }
    }

    /// Whether the server closed the connection within 5 s, reading and discarding what it sent first.
    func closedByServer() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(socket, $0.baseAddress, $0.count) }
            if count == 0 || (count < 0 && errno == ECONNRESET) { return true }
            if count < 0 { return false }  // timed out: still open
        }
    }
}
