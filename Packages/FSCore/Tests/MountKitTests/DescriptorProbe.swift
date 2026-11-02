import Darwin

/// A descriptor whose closing a test can see: the read end of a pipe. Descriptor numbers are reused at once by tests running in
/// parallel, so `fcntl(fd, F_GETFD)` cannot tell; a write to the write end fails with EPIPE once every read end is closed.
final class DescriptorProbe {
    let descriptor: Int32
    private let writeEnd: Int32

    init() {
        var ends: [Int32] = [0, 0]
        _ = pipe(&ends)
        descriptor = ends[0]
        writeEnd = ends[1]
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        // Close-on-exec: a process another test spawns meanwhile would otherwise inherit the read end and keep it open.
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        // Close-on-exec: a process another test spawns meanwhile would otherwise inherit the read end and keep it open.
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
        // Close-on-exec: a process another test spawns meanwhile would otherwise inherit the read end and keep it open.
        for end in ends { _ = fcntl(end, F_SETFD, FD_CLOEXEC) }
    }

    var isClosed: Bool {
        var byte: UInt8 = 0
        return write(writeEnd, &byte, 1) == -1 && errno == EPIPE
    }

    /// For a test that keeps ownership: closes the read end it never handed over.
    func closeDescriptor() { close(descriptor) }

    deinit { close(writeEnd) }
}
