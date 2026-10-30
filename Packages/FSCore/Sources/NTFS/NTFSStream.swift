import AemiKernel
import FSCore

/// The content of one attribute, resident or spread over runs, readable at any offset.
struct NTFSStream: Sendable {
    let size: UInt64
    private let initialized: UInt64
    private let resident: DiskBytes?
    private let runs: [DataRun]
    private let clusterSize: Int

    /// Joins the extents of one attribute. Compressed and encrypted streams are refused here, before
    /// any byte of them is handed out as if it were plain data.
    init(_ extents: [NTFSAttribute], clusterSize: Int) throws(DiskError) {
        guard let first = extents.first else { throw .notFound }
        if first.flags & NTFSAttribute.encrypted != 0 { throw .accessDenied("EFS-encrypted stream") }
        if first.flags & NTFSAttribute.compressed != 0 { throw .unsupported("LZNT1-compressed streams") }
        self.clusterSize = clusterSize
        if let value = first.value {
            size = UInt64(value.count)
            initialized = size
            resident = value
            runs = []
            return
        }
        guard let head = first.nonResident else { throw .corrupt("attribute is neither resident nor not") }
        size = head.dataSize
        initialized = min(head.initializedSize, head.dataSize)
        resident = nil
        var runs: [DataRun] = []
        for extent in extents {
            guard let part = extent.nonResident else { throw .corrupt("a resident extent among runs") }
            runs += part.runs
        }
        for (previous, next) in zip(runs, runs.dropFirst()) where previous.vcn + previous.length != next.vcn {
            throw .corrupt("runs leave a gap at VCN \(previous.vcn + previous.length)")
        }
        guard size <= (runs.last.map { ($0.vcn + $0.length) * UInt64(clusterSize) } ?? 0) else {
            throw .corrupt("stream of \(size) bytes in fewer clusters")
        }
        self.runs = runs
    }

    /// Up to `count` bytes at `offset`; fewer at the end. Bytes past the initialized size read as zero.
    func read(_ source: any BlockSource, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard offset < size, count > 0 else { return [] }
        let end = min(size, offset + UInt64(count))
        if let resident { return try resident.bytes(Int(offset), Int(end - offset)) }
        var output = [UInt8](repeating: 0, count: Int(end - offset))
        let cluster = UInt64(clusterSize)
        var position = offset
        let readable = min(end, initialized)
        while position < readable {
            let vcn = position / cluster
            let run = try self.run(containing: vcn)
            let runEnd = min(readable, (run.vcn + run.length) * cluster)
            let span = Int(runEnd - position)
            if let lcn = run.cluster {
                guard let physical = (lcn + vcn - run.vcn).checkedMultiplied(by: cluster) else {
                    throw .corrupt("cluster \(lcn)")
                }
                let bytes = try source.read(at: physical + position % cluster, count: span)
                let target = Int(position - offset)
                output.replaceSubrange(target ..< (target + span), with: bytes)
            }
            position = runEnd
        }
        return output
    }

    private func run(containing vcn: UInt64) throws(DiskError) -> DataRun {
        guard let index = runs.lastIndex(atOrBefore: vcn, by: \.vcn), vcn < runs[index].vcn + runs[index].length else {
            throw .corrupt("VCN \(vcn) is in no run")
        }
        return runs[index]
    }
}
