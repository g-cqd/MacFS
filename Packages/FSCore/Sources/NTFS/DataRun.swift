import AemiKernel
import FSCore

/// A contiguous range of clusters of a non-resident attribute. `cluster` nil is a sparse run.
struct DataRun: Sendable, Equatable {
    let vcn: UInt64
    let length: UInt64
    let cluster: UInt64?

    /// Decodes mapping pairs: a header byte (length size, offset size), the length, then an offset
    /// relative to the previous run's cluster, signed. A zero header ends the list.
    static func decode(_ bytes: DiskBytes, firstVCN: UInt64, lastVCN: UInt64) throws(DiskError) -> [DataRun] {
        var runs: [DataRun] = []
        var cursor = 0
        var vcn = firstVCN
        var cluster: Int64 = 0
        while cursor < bytes.count {
            let header = try bytes.u8(cursor)
            if header == 0 { break }
            let lengthSize = Int(header & 0x0F)
            let offsetSize = Int(header >> 4)
            guard (1 ... 8).contains(lengthSize), offsetSize <= 8 else { throw .corrupt("data run header \(header)") }
            let length = try unsigned(bytes, cursor + 1, lengthSize)
            guard length > 0, let next = vcn.checkedAdding(length) else {
                throw .corrupt("data run of \(length) clusters")
            }
            if offsetSize == 0 {
                runs.append(DataRun(vcn: vcn, length: length, cluster: nil))
            } else {
                let delta = try signed(bytes, cursor + 1 + lengthSize, offsetSize)
                let (sum, overflow) = cluster.addingReportingOverflow(delta)
                guard !overflow, sum >= 0 else { throw .corrupt("data run before cluster 0") }
                cluster = sum
                runs.append(DataRun(vcn: vcn, length: length, cluster: UInt64(sum)))
            }
            vcn = next
            cursor += 1 + lengthSize + offsetSize
        }
        guard vcn == firstVCN || vcn - 1 <= lastVCN else {
            throw .corrupt("data runs end at VCN \(vcn), past \(lastVCN)")
        }
        return runs
    }

    private static func unsigned(_ bytes: DiskBytes, _ at: Int, _ size: Int) throws(DiskError) -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< size { value |= UInt64(try bytes.u8(at + index)) << (8 * index) }
        return value
    }

    private static func signed(_ bytes: DiskBytes, _ at: Int, _ size: Int) throws(DiskError) -> Int64 {
        let raw = try unsigned(bytes, at, size)
        let shift = UInt64(64 - 8 * size)
        return Int64(bitPattern: raw << shift) >> Int64(shift)
    }
}
