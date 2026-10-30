import Darwin

/// The baseline (docs/conformance/performance.md): the same workload as a reader's walk, on a directory of the host's own file
/// system through POSIX: `opendir`/`readdir`, `lstat`, `open` and `read` in 1 MiB pieces, depth first, no recursion.
enum NativeWalk {
    struct Result {
        var nodes = 0
        var bytes: UInt64 = 0
    }

    static func walk(_ root: String) -> Result {
        var result = Result()
        var pending = [root]
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16384)
        defer { buffer.deallocate() }
        while let directory = pending.popLast() {
            guard let handle = opendir(directory) else { continue }
            defer { closedir(handle) }
            while let entry = readdir(handle) {
                // d_name is NUL-terminated: read whole, never cut.
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                guard name != ".", name != ".." else { continue }
                let path = directory + "/" + name
                result.nodes += 1
                var status = stat()
                guard lstat(path, &status) == 0 else { continue }
                switch status.st_mode & S_IFMT {
                    case S_IFDIR:
                        pending.append(path)
                    case S_IFREG:
                        let file = open(path, O_RDONLY)
                        guard file >= 0 else { continue }
                        while true {
                            let count = read(file, buffer, 1 << 20)
                            if count <= 0 { break }
                            result.bytes += UInt64(count)
                        }
                        close(file)
                    default:
                        break
                }
            }
        }
        return result
    }
}
