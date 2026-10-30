public import FSCore

extension NTFSFileSystem {
    private static let windowsEpochOffset: Int64 = 11_644_473_600

    public func attributes(of id: UInt64) throws(DiskError) -> NodeAttributes {
        guard id == rootID || id >= Self.firstUserRecord else { throw .notFound }
        let record = try record(id)
        let names = record.attributes.filter { $0.type == NTFSAttributeType.fileName }
            .compactMap { $0.value.flatMap { try? NTFSFileName($0) } }
            .filter { $0.namespace != NTFSFileName.dosNamespace }
        var kind: NodeKind = record.flags & NTFSRecord.directory != 0 ? .directory : .regular
        if kind == .regular, let reparse = record.first(NTFSAttributeType.reparsePoint)?.value,
            NTFSReparse.isLink(tag: try reparse.u32(0))
        {
            kind = .symlink
        } else if kind == .regular, try interixTarget(record) != nil {
            kind = .symlink
        }
        let parent = id == rootID ? rootID : names.first?.parent ?? rootID
        var attributes = NodeAttributes(id: id, parent: parent, kind: kind)
        attributes.linkCount = UInt32(max(1, names.count))
        if let information = record.first(NTFSAttributeType.standardInformation)?.value {
            attributes.created = try Self.time(try information.u64(0))
            attributes.modified = try Self.time(try information.u64(8))
            attributes.changed = try Self.time(try information.u64(16))
            attributes.accessed = try Self.time(try information.u64(24))
            attributes.isHidden = try information.u32(32) & 0x02 != 0
        }
        switch kind {
            case .regular:
                if let data = record.extents(NTFSAttributeType.data).first {
                    attributes.size = data.size
                    attributes.allocatedSize = data.nonResident?.allocatedSize ?? UInt64(data.value?.count ?? 0)
                }
            case .symlink:
                attributes.size = UInt64(try readLink(id).count)
            case .directory:
                // ntfs-3g's rule: the data size of the $I30 index allocation, or 0 when the index fits in its root.
                if let index = record.extents(NTFSAttributeType.indexAllocation, named: Self.indexName).first {
                    attributes.size = index.size
                    attributes.allocatedSize = index.nonResident?.allocatedSize ?? 0
                }
            default:
                break
        }
        return attributes
    }

    /// 100-nanosecond intervals since 1601 to Unix time.
    private static func time(_ value: UInt64) throws(DiskError) -> Timestamp {
        let seconds = Int64(value / 10_000_000) - windowsEpochOffset
        return Timestamp(seconds: seconds, nanoseconds: Int32(value % 10_000_000) * 100)
    }

    public func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8] {
        let record = try record(id)
        guard record.flags & NTFSRecord.directory == 0 else { throw .isDirectory }
        return try stream(record, NTFSAttributeType.data).read(source, at: offset, count: count)
    }

    public func readLink(_ id: UInt64) throws(DiskError) -> [UInt8] {
        let record = try record(id)
        if let value = record.first(NTFSAttributeType.reparsePoint)?.value { return try NTFSReparse.target(value) }
        guard let target = try interixTarget(record) else { throw .notSymlink }
        return target
    }

    /// The target when the record is an Interix link (ntfs-3g's default): the system attribute, and small data that starts
    /// with the link tag.
    func interixTarget(_ record: NTFSRecord) throws(DiskError) -> [UInt8]? {
        guard let information = record.first(NTFSAttributeType.standardInformation)?.value,
            try information.u32(32) & NTFSInterix.systemFlag != 0,
            let data = record.extents(NTFSAttributeType.data).first,
            data.size >= UInt64(NTFSInterix.linkMagic.count), data.size <= UInt64(NTFSInterix.largestLink)
        else { return nil }
        let bytes = try stream(record, NTFSAttributeType.data).read(source, at: 0, count: Int(data.size))
        return try NTFSInterix.linkTarget(bytes)
    }
}
