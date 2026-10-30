import FSCore
import Synchronization
import Testing

/// A device that only accepts aligned transfers and records them, standing in for a raw disk.
final class StrictDevice: Sendable {
    let bytes: [UInt8]
    let alignment: Int
    let requests = Mutex<[(UInt64, Int)]>([])

    init(size: Int, alignment: Int) {
        self.bytes = (0 ..< size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        self.alignment = alignment
    }

    func read(_ offset: UInt64, _ count: Int) throws(DiskError) -> [UInt8] {
        requests.withLock { $0.append((offset, count)) }
        guard offset % UInt64(alignment) == 0, count % alignment == 0 else { throw .io(errno: 22, "unaligned") }
        return Array(bytes[Int(offset) ..< (Int(offset) + count)])
    }
}

@Suite struct AlignedReaderTests {
    @Test func unalignedRequestsBecomeAlignedTransfersAndAreTrimmed() throws {
        let device = StrictDevice(size: 8192, alignment: 512)
        let reader = AlignedReader(byteCount: 8192, alignment: 512) { (offset, count) throws(DiskError) in
            try device.read(offset, count)
        }
        for (offset, count) in [(0, 1), (1, 1), (511, 2), (100, 1000), (7000, 1192), (4096, 0), (0, 8192)] {
            let got = try reader.read(at: UInt64(offset), count: count)
            #expect(got == Array(device.bytes[offset ..< (offset + count)]), "\(offset)+\(count)")
        }
        #expect(device.requests.withLock { $0.allSatisfy { $0.0 % 512 == 0 && $0.1 % 512 == 0 } })
    }

    @Test func readsPastTheEndThrowWithoutTouchingTheDevice() {
        let device = StrictDevice(size: 4096, alignment: 512)
        let reader = AlignedReader(byteCount: 4096, alignment: 512) { (offset, count) throws(DiskError) in
            try device.read(offset, count)
        }
        #expect(throws: DiskError.self) { try reader.read(at: 4000, count: 97) }
        #expect(throws: DiskError.self) { try reader.read(at: .max, count: 2) }
        #expect(device.requests.withLock { $0.isEmpty })
    }

    @Test func alignmentOneIsPassThrough() throws {
        let device = StrictDevice(size: 100, alignment: 1)
        let reader = AlignedReader(byteCount: 100, alignment: 1) { (offset, count) throws(DiskError) in
            try device.read(offset, count)
        }
        _ = try reader.read(at: 3, count: 5)
        #expect(device.requests.withLock { $0.map(\.0) == [3] && $0.map(\.1) == [5] })
    }
}
