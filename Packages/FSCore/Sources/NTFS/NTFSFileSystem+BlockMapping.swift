public import FSCore

/// Where a file's bytes lie, for kernel-offloaded I/O (roadmap 0018): the unnamed $DATA stream's runs, sparse runs as zero.
/// Resident, compressed and encrypted streams, and a stream initialized short of its size (whose last cluster holds bytes that
/// must read as zero), stay with `read`.
extension NTFSFileSystem: BlockMapping {
    public func isMappable(_ id: UInt64) throws(DiskError) -> Bool {
        let record = try record(id)
        guard record.flags & NTFSRecord.directory == 0, try interixTarget(record) == nil,
            let stream = try? stream(record, NTFSAttributeType.data)
        else { return false }
        return stream.mappedRanges != nil
    }

    public func blockMap(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange] {
        let stream = try stream(try record(id), NTFSAttributeType.data)
        guard let ranges = stream.mappedRanges else { throw .unsupported("record \(id) is not stored as its bytes") }
        return MappedRange.clip(
            ranges,
            offset: offset,
            length: length,
            size: stream.size,
            unit: UInt64(boot.clusterSize)
        )
    }
}
