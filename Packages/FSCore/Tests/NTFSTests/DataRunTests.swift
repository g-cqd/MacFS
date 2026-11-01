import FSCore
import Testing

@testable import NTFS

// Mapping-pair vectors worked by hand from the format (header nibbles: offset size, length size).
@Suite struct DataRunTests {
    @Test func positiveNegativeAndSparseRuns() throws {
        let bytes: [UInt8] = [
            0x21, 0x18, 0x34, 0x56,  // 0x18 clusters at 0x5634
            0x11, 0x04, 0xF0,  // 4 clusters at 0x5634 - 0x10
            0x01, 0x08,  // 8 sparse clusters
            0x31, 0x02, 0x00, 0x00, 0x01,  // 2 clusters at previous + 0x10000
            0x00
        ]
        let runs = try DataRun.decode(DiskBytes(bytes), firstVCN: 0, lastVCN: 0x25)
        #expect(
            runs == [
                DataRun(vcn: 0, length: 0x18, cluster: 0x5634),
                DataRun(vcn: 0x18, length: 4, cluster: 0x5624),
                DataRun(vcn: 0x1C, length: 8, cluster: nil),
                DataRun(vcn: 0x24, length: 2, cluster: 0x15624)
            ]
        )
    }

    @Test func runsBeforeClusterZeroAreCorrupt() {
        #expect(throws: DiskError.self) {
            try DataRun.decode(DiskBytes([0x11, 0x01, 0xFF, 0x00]), firstVCN: 0, lastVCN: 0)
        }
    }

    @Test func runsPastTheLastVCNAreCorrupt() {
        #expect(throws: DiskError.self) {
            try DataRun.decode(DiskBytes([0x11, 0x10, 0x05, 0x00]), firstVCN: 0, lastVCN: 3)
        }
    }

    @Test func oversizedFieldsAreCorrupt() {
        #expect(throws: DiskError.self) {
            try DataRun.decode(DiskBytes([0x19, 0x01, 0x05, 0x00]), firstVCN: 0, lastVCN: 0)
        }
        #expect(throws: DiskError.self) { try DataRun.decode(DiskBytes([0x10, 0x01, 0x00]), firstVCN: 0, lastVCN: 0) }
    }
}
