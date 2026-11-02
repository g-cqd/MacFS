import Dispatch
import FSCore
import Synchronization
import Testing

@testable import ExtFS

/// The writer under concurrent callers (roadmap 0046): macOS's NFS client keeps several WRITEs in flight, and the proxy
/// serves them at once. Measured before the writer serialized its changes: `cp` of 4 MiB kept 917,504 bytes and exited 0, as
/// two writes each read the inode, grew it and wrote it back, the last one losing the other's blocks or size.
@Suite struct ExtConcurrentWriteTests {
    /// The errors the threads met.
    final class ErrorBox: Sendable {
        private let errors = Mutex<[DiskError]>([])
        func add(_ error: DiskError) { errors.withLock { $0.append(error) } }
        var all: [DiskError] { errors.withLock { $0 } }
    }

    @Test func concurrentWritesToOneFileAllLand() async throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let file = try volume.create(Array("f.bin".utf8), kind: .regular, in: volume.rootID, mode: 0o644, owner: (0, 0))
        let chunk = 131_072
        let chunks = 16
        let data = (0 ..< chunk * chunks).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }
        let errors = ErrorBox()
        DispatchQueue.concurrentPerform(iterations: chunks) { index in
            do throws(DiskError) {
                let start = index * chunk
                try volume.write(file, at: UInt64(start), Array(data[start ..< start + chunk]))
            } catch {
                errors.add(error)
            }
        }
        #expect(errors.all.isEmpty, "\(errors.all)")
        #expect(try volume.attributes(of: file).size == UInt64(data.count))
        #expect(try volume.read(file, at: 0, count: data.count) == data)
        try volume.close()
        #expect(try ExtFileSystem(source: device).read(file, at: 0, count: data.count) == data)
        try await ExtNamespaceTests.e2fsck(device)
    }

    @Test func concurrentCreatesInOneDirectoryAllLand() async throws {
        let (device, volume) = try ExtNamespaceTests.open()
        let errors = ErrorBox()
        DispatchQueue.concurrentPerform(iterations: 24) { index in
            do throws(DiskError) {
                _ = try volume.create(
                    Array("n\(index)".utf8),
                    kind: index % 3 == 0 ? .directory : .regular,
                    in: volume.rootID,
                    mode: 0o644,
                    owner: (0, 0)
                )
            } catch {
                errors.add(error)
            }
        }
        #expect(errors.all.isEmpty, "\(errors.all)")
        for index in 0 ..< 24 {
            #expect(throws: Never.self) { try volume.lookup(Array("n\(index)".utf8), in: volume.rootID) }
        }
        try volume.close()
        try await ExtNamespaceTests.e2fsck(device)
    }
}
