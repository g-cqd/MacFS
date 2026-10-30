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
        guard let value = try record(id).first(NTFSAttributeType.reparsePoint)?.value else { throw .notSymlink }
        return try NTFSReparse.target(value)
    }
}
