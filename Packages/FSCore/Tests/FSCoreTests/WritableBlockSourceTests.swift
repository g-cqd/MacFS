import AemiIO
import FSCore
import Foundation
import Testing

/// The device writes go to (ADR-0018): exact bytes at an offset, nothing past the end, and a flush that is a barrier.
struct WritableBlockSourceTests {
    @Test func aMemorySourceReadsBackWhatWasWritten() throws {
        let source = MemoryBlockSource([UInt8](repeating: 0, count: 16))
        try source.write(at: 4, [1, 2, 3])
        try source.flush()
        #expect(try source.read(at: 3, count: 5) == [0, 1, 2, 3, 0])
        #expect(source.bytes == [0, 0, 0, 0, 1, 2, 3] + [UInt8](repeating: 0, count: 9))
    }

    @Test func aWritePastTheEndIsRefusedAndChangesNothing() {
        let source = MemoryBlockSource([UInt8](repeating: 0, count: 8))
        #expect(throws: DiskError.self) { try source.write(at: 6, [1, 2, 3]) }
        #expect(source.bytes == [UInt8](repeating: 0, count: 8))
    }

    @Test func aFileOpenedWritableKeepsItsWritesAcrossOpens() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wbs-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: Data(count: 4096))
        let source = try FileBlockSource(path: path, writable: true)
        try source.write(at: 1000, [7, 8, 9])
        try source.flush()
        #expect(try FileBlockSource(path: path).read(at: 999, count: 5) == [0, 7, 8, 9, 0])
    }

    /// A raw device takes whole sectors only (a 1-byte `dd` to one is refused): a write inside a sector is read, patched and
    /// written whole. Live, on a scratch image attached without mounting; its file is read back after detaching.
    @Test func aDeviceWriteInsideASectorKeepsTheRestOfIt() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wbs-\(UUID().uuidString).img").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(
            atPath: path,
            contents: Data((0 ..< 1 << 20).map { UInt8(truncatingIfNeeded: $0 / 512) })
        )
        let device = try Self.attach(path)
        defer { Self.hdiutil(["detach", "-force", device]) }
        do {
            // Its own scope: the descriptor closes before the detach, which a held device refuses.
            let source = try FileBlockSource(
                path: device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"),
                writable: true
            )
            #expect(source.alignment == 512)
            try source.write(at: 1000, [7, 8, 9])
            try source.flush()
        }
        Self.hdiutil(["detach", device])
        let bytes = try FileBlockSource(path: path).read(at: 998, count: 7)
        #expect(bytes == [1, 1, 7, 8, 9, 1, 1])
    }

    static func attach(_ path: String) throws -> String {
        let output = hdiutil(["attach", "-nomount", path])
        return try #require(output.split(separator: "\n").first?.split(separator: "\t").first)
            .trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    static func hdiutil(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }

    /// A source opened read-only refuses writes as a read-only file system does: EROFS.
    @Test func aFileOpenedReadOnlyRefusesWrites() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("wbs-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: Data(count: 512))
        let source = try FileBlockSource(path: path)
        #expect(throws: DiskError.readOnly) { try source.write(at: 0, [1]) }
        #expect(DiskError.readOnly.posixCode == EROFS)
    }
}
