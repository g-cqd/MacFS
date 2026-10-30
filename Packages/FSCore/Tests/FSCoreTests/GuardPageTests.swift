import AemiTestKit
import CFSKernels
import Testing

/// The NTFS fixups kernel (assembly on arm64) with its record flush against an inaccessible page, at the end and at the start:
/// a read or write beyond the record crashes, which no result comparison could show. aemi tests the kernels FSCore takes from
/// it the same way (its ADR 0021).
@Suite struct GuardPageTests {
    @Test(arguments: GuardedBytes.Edge.allCases)
    func fixupsStayInsideTheRecord(edge: GuardedBytes.Edge) {
        var random = SplitMix(state: 5)
        for (size, stride) in [(512, 512), (1024, 512), (4096, 512), (4096, 4096), (64, 8), (16, 8), (8, 2)] {
            for trial in 0 ..< 40 {
                var record = random.bytes(size)
                let entries = size / stride + 1
                if trial % 5 == 1, size >= 8 {
                    // The right count with the array pushed past the end: only the bounds check refuses it, and a kernel
                    // without one reads (and writes) beyond the record.
                    let offset = (size - 2 * entries + 2 + 1) & ~1
                    record[4] = UInt8(offset & 0xFF)
                    record[5] = UInt8(offset >> 8)
                    record[6] = UInt8(entries & 0xFF)
                    record[7] = UInt8(entries >> 8)
                } else if 8 + 2 * entries <= size, trial % 5 != 0 {
                    // A valid header (array at 8), and on even trials strides that end with the sequence number.
                    record[4] = 8
                    record[5] = 0
                    record[6] = UInt8(entries & 0xFF)
                    record[7] = UInt8(entries >> 8)
                    if trial % 2 == 0 {
                        for index in 1 ..< entries {
                            record[index * stride - 2] = record[8]
                            record[index * stride - 1] = record[9]
                        }
                    }
                }
                var expected = record
                let status = expected.withUnsafeMutableBufferPointer { referenceFixups($0.baseAddress!, size, stride) }
                GuardedBytes.with(record, against: edge) { base in
                    #expect(fsk_ntfs_apply_fixups(base, size, stride) == status, "\(size)/\(stride), trial \(trial)")
                    if status == 0 { #expect(Array(UnsafeBufferPointer(start: base, count: size)) == expected) }
                }
            }
        }
    }
}
