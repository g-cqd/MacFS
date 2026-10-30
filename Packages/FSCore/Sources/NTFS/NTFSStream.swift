import AemiKernel
import FSCore

/// The content of one attribute, resident or spread over runs, readable at any offset.
struct NTFSStream: Sendable {
    let size: UInt64
    private let initialized: UInt64
    private let resident: DiskBytes?
    private let runs: [DataRun]
    private let clusterSize: Int
    /// Clusters per compression unit when the stream is LZNT1-compressed (roadmap 0014).
    private let unitClusters: Int?

    /// Joins the extents of one attribute. Encrypted streams, and compression other than LZNT1, are refused here, before any
    /// byte of them is handed out as if it were plain data. A resident value is never compressed, whatever its flags say.
    init(_ extents: [NTFSAttribute], clusterSize: Int) throws(DiskError) {
        guard let first = extents.first else { throw .notFound }
        if first.flags & NTFSAttribute.encrypted != 0 { throw .accessDenied("EFS-encrypted stream") }
        self.clusterSize = clusterSize
        if let value = first.value {
            size = UInt64(value.count)
            initialized = size
            resident = value
            runs = []
            unitClusters = nil
            return
        }
        guard let head = first.nonResident else { throw .corrupt("attribute is neither resident nor not") }
        switch first.flags & NTFSAttribute.compressionMask {
            case 0:
                unitClusters = nil
            case NTFSAttribute.compressed:
                // LZNT1 works in 4 KiB chunks and Windows compresses only volumes of clusters up to 4 KiB.
                guard (1 ... 8).contains(head.compressionUnit), clusterSize <= 4096 else {
                    throw .corrupt("compression unit 2^\(head.compressionUnit) of \(clusterSize)-byte clusters")
                }
                unitClusters = 1 << Int(head.compressionUnit)
            default:
                throw .unsupported(
                    "NTFS compression 0x\(String(first.flags & NTFSAttribute.compressionMask, radix: 16))")
        }
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

    /// The runs as byte ranges on the volume, sparse runs as zero; nil when the stream is resident or initialized short of its
    /// size (block maps, roadmap 0018).
    var mappedRanges: [MappedRange]? {
        guard resident == nil, initialized == size, unitClusters == nil else { return nil }
        let cluster = UInt64(clusterSize)
        return runs.map { run in
            MappedRange(
                logical: run.vcn * cluster, length: run.length * cluster, physical: run.cluster.map { $0 * cluster })
        }
    }

    /// Up to `count` bytes at `offset`; fewer at the end. Bytes past the initialized size read as zero.
    func read(_ source: any BlockSource, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        guard offset < size, count > 0 else { return [] }
        let end = min(size, offset + UInt64(count))
        if let resident { return try resident.bytes(Int(offset), Int(end - offset)) }
        if let unitClusters { return try compressedRead(source, from: offset, to: end, unitClusters: unitClusters) }
        let cluster = UInt64(clusterSize)
        let readable = min(end, initialized)
        // Each run straight from the volume into the result; sparse runs and the uninitialized tail stay zero.
        return try ReadAssembly.assemble(count: Int(end - offset)) { (pieces) throws(DiskError) in
            var position = offset
            while position < readable {
                let vcn = position / cluster
                let run = try self.run(containing: vcn)
                let runEnd = min(readable, (run.vcn + run.length) * cluster)
                if let lcn = run.cluster {
                    guard let physical = (lcn + vcn - run.vcn).checkedMultiplied(by: cluster) else {
                        throw .corrupt("cluster \(lcn)")
                    }
                    try pieces.read(
                        source, at: physical + position % cluster, to: Int(position - offset),
                        count: Int(runEnd - position))
                }
                position = runEnd
            }
        }
    }

    /// `offset ..< end` of a compressed stream (ntfs-3g's `ntfs_compressed_attr_pread`), built in place: a unit with no
    /// cluster allocated is zeros, one with every cluster allocated is stored as is and read straight from the volume, and one
    /// with some allocated holds LZNT1 chunks in those clusters, decoded straight into the result when the read covers the
    /// whole unit. Bytes past the initialized size read as zero.
    private func compressedRead(
        _ source: any BlockSource, from offset: UInt64, to end: UInt64, unitClusters: Int
    ) throws(DiskError) -> [UInt8] {
        let cluster = UInt64(clusterSize)
        let unitBytes = UInt64(unitClusters) * cluster
        let readable = min(end, initialized)
        return try ReadAssembly.assemble(count: Int(end - offset)) { (pieces) throws(DiskError) in
            var unit = offset / unitBytes
            while unit * unitBytes < readable {
                let start = unit * unitBytes
                let (from, to) = (max(offset, start), min(readable, start + unitBytes))
                let parts = try self.parts(of: unit, clusters: unitClusters)
                let allocated = parts.reduce(UInt64(0)) { $0 + ($1.cluster == nil ? 0 : $1.length) }
                if allocated == UInt64(unitClusters) {
                    for part in parts {
                        let (low, high) = (max(from, part.vcn * cluster), min(to, (part.vcn + part.length) * cluster))
                        guard low < high, let lcn = part.cluster else { continue }
                        try pieces.read(
                            source, at: lcn * cluster + low - part.vcn * cluster, to: Int(low - offset),
                            count: Int(high - low))
                    }
                } else if allocated > 0 {
                    let stored = try self.stored(source, parts)
                    if from == start, to == start + unitBytes {
                        try unsafe pieces.fill(to: Int(start - offset), count: Int(unitBytes)) {
                            (region) throws(DiskError) in
                            try unsafe LZNT1.decompress(stored, into: region.assumingMemoryBound(to: UInt8.self))
                        }
                    } else {
                        let content = try LZNT1.decompress(stored, capacity: Int(unitBytes))
                        try pieces.copy(content[Int(from - start) ..< Int(to - start)], to: Int(from - offset))
                    }
                }
                unit += 1
            }
        }
    }

    /// The runs of one compression unit, clipped to it, in order; clusters past the last run count as sparse.
    func parts(of unit: UInt64, clusters: Int) throws(DiskError) -> [DataRun] {
        let first = unit * UInt64(clusters)
        let last = first + UInt64(clusters)
        var parts: [DataRun] = []
        var vcn = first
        while vcn < last, let index = runs.lastIndex(atOrBefore: vcn, by: \.vcn),
            vcn < runs[index].vcn + runs[index].length
        {
            let run = runs[index]
            let count = min(last, run.vcn + run.length) - vcn
            parts.append(DataRun(vcn: vcn, length: count, cluster: run.cluster.map { $0 + vcn - run.vcn }))
            vcn += count
        }
        return parts
    }

    /// The allocated clusters of a unit's parts, as they are on the volume: a compressed unit's LZNT1 chunks.
    func stored(_ source: any BlockSource, _ parts: [DataRun]) throws(DiskError) -> [UInt8] {
        let cluster = UInt64(clusterSize)
        var bytes: [UInt8] = []
        for part in parts {
            guard let lcn = part.cluster else { continue }
            guard let physical = lcn.checkedMultiplied(by: cluster) else { throw .corrupt("cluster \(lcn)") }
            bytes += try source.read(at: physical, count: Int(part.length * cluster))
        }
        return bytes
    }

    /// Clusters per compression unit, when the stream is compressed.
    var compressionUnitClusters: Int? { unitClusters }

    private func run(containing vcn: UInt64) throws(DiskError) -> DataRun {
        guard let index = runs.lastIndex(atOrBefore: vcn, by: \.vcn), vcn < runs[index].vcn + runs[index].length else {
            throw .corrupt("VCN \(vcn) is in no run")
        }
        return runs[index]
    }
}
