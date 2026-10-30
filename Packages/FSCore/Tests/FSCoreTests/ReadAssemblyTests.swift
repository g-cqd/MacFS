import FSCore
import Foundation
import Testing

/// A block source over bytes in memory.
struct MemorySource: BlockSource {
    let bytes: [UInt8]
    var byteCount: UInt64 { UInt64(bytes.count) }
    func read(at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard offset <= byteCount, UInt64(count) <= byteCount - offset else { throw .corrupt("past the end") }
        return Array(bytes[Int(offset) ..< Int(offset) + count])
    }
}

/// `ReadAssembly`: a read's result built in place, every byte either read or zero, pieces in order (performance baseline).
@Suite struct ReadAssemblyTests {
    let source = MemorySource(bytes: (0 ..< 64).map { UInt8($0) })

    @Test func piecesLandWhereTheyAreToldAndEverythingElseIsZero() throws {
        let result = try ReadAssembly.assemble(count: 16) { (pieces) throws(DiskError) in
            try pieces.read(source, at: 10, to: 2, count: 3)
            try pieces.copy([0xAA, 0xBB], to: 8)
        }
        #expect(result == [0, 0, 10, 11, 12, 0, 0, 0, 0xAA, 0xBB, 0, 0, 0, 0, 0, 0])
    }

    @Test func nothingReadIsAllZero() throws {
        #expect(try ReadAssembly.assemble(count: 5) { (_) throws(DiskError) in } == [0, 0, 0, 0, 0])
        #expect(try ReadAssembly.assemble(count: 0) { (_) throws(DiskError) in }.isEmpty)
    }

    @Test func piecesOutOfOrderOrOverlappingOrOutsideAreCorrupt() {
        #expect(throws: DiskError.self) {
            try ReadAssembly.assemble(count: 8) { (pieces) throws(DiskError) in
                try pieces.copy([1, 2], to: 4)
                try pieces.copy([3], to: 1)
            }
        }
        #expect(throws: DiskError.self) {
            try ReadAssembly.assemble(count: 8) { (pieces) throws(DiskError) in
                try pieces.copy([1, 2, 3], to: 0)
                try pieces.copy([4], to: 2)
            }
        }
        #expect(throws: DiskError.self) {
            try ReadAssembly.assemble(count: 4) { (pieces) throws(DiskError) in try pieces.copy([1, 2], to: 3) }
        }
    }

    @Test func aFailingSourceFailsTheRead() {
        #expect(throws: DiskError.self) {
            try ReadAssembly.assemble(count: 8) { (pieces) throws(DiskError) in
                try pieces.read(source, at: 60, to: 0, count: 8)
            }
        }
    }

    /// A file source reads straight into the caller's memory, with the same bytes and the same refusals as `read`.
    @Test func aFileSourceReadsIntoMemoryAsItReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("read-assembly-\(UUID()).bin")
        try Data((0 ..< 10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileBlockSource(path: url.path)
        var into = [UInt8](repeating: 0xEE, count: 777)
        try into.withUnsafeMutableBytes { raw in try file.read(at: 4321, into: raw) }
        #expect(into == (try file.read(at: 4321, count: 777)))
        #expect(throws: DiskError.self) {
            var tail = [UInt8](repeating: 0, count: 10)
            try tail.withUnsafeMutableBytes { raw in try file.read(at: 9995, into: raw) }
        }
    }
}
