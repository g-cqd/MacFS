import AemiKernel
public import FSCore

extension NTFSFileSystem {
    static let indexName = Array("$I30".utf8)

    /// Every entry of the `$I30` index: the root's, then every INDX block reachable from it.
    func listing(_ directory: UInt64) throws(DiskError) -> NTFSListing {
        try listings.value(for: directory) { () throws(DiskError) -> NTFSListing in
            let record = try record(directory)
            guard record.flags & NTFSRecord.directory != 0,
                let root = record.first(NTFSAttributeType.indexRoot, named: Self.indexName),
                let rootValue = root.value
            else { throw .notDirectory }
            let blockSize = Int(try rootValue.u32(8))
            guard blockSize >= 512, blockSize <= 1 << 16 else { throw .corrupt("index block of \(blockSize) bytes") }
            var names: [NTFSListing.Name] = []
            var pending = try entries(in: try rootValue.slice(from: 16), into: &names)
            guard !pending.isEmpty else { return NTFSListing(names) }
            let allocation = try stream(record, NTFSAttributeType.indexAllocation, named: Self.indexName)
            // VCNs count clusters, or 512-byte units when index blocks are smaller than a cluster.
            let unit = UInt64(blockSize >= boot.clusterSize ? boot.clusterSize : 512)
            var seen: Set<UInt64> = []
            while let vcn = pending.popLast() {
                guard seen.insert(vcn).inserted, seen.count <= 1 << 20 else {
                    throw .corrupt("index block \(vcn) is reachable twice")
                }
                guard let offset = vcn.checkedMultiplied(by: unit) else { throw .corrupt("index VCN \(vcn)") }
                let block = try NTFSMultiSector.restore(
                    try allocation.read(source, at: offset, count: blockSize), magic: "INDX", size: blockSize,
                    what: "index block \(vcn) of directory \(directory)")
                pending += try entries(in: try DiskBytes(block).slice(from: 0x18), into: &names)
            }
            return NTFSListing(names)
        }
    }

    /// Appends the visible names of one index node (header at the start of `node`) and returns the
    /// VCNs of the child blocks it points to.
    private func entries(in node: DiskBytes, into names: inout [NTFSListing.Name]) throws(DiskError) -> [UInt64] {
        let first = Int(try node.u32(0))
        let end = Int(try node.u32(4))
        guard first >= 16, end <= node.count, first <= end else {
            throw .corrupt("index node \(first)..\(end) in \(node.count)")
        }
        var children: [UInt64] = []
        var cursor = first
        while cursor + 16 <= end {
            let length = Int(try node.u16(cursor + 8))
            let keyLength = Int(try node.u16(cursor + 10))
            let flags = try node.u16(cursor + 12)
            guard length >= 16, cursor + length <= end else { throw .corrupt("index entry of \(length) bytes") }
            if flags & 1 != 0 { children.append(try node.u64(cursor + length - 8)) }
            if flags & 2 != 0 { break }
            let record = try node.u64(cursor) & 0xFFFF_FFFF_FFFF
            let name = try NTFSFileName(try node.slice(cursor + 16, keyLength))
            if record >= Self.firstUserRecord, name.namespace != NTFSFileName.dosNamespace {
                names.append(NTFSListing.Name(record: record, fileName: name, folded: fold(name.units)))
            }
            cursor += length
        }
        return children
    }

    /// The kind an index entry names. Only a system file can be an Interix link, so only those cost a record read.
    func kind(_ name: NTFSFileName, record: UInt64) -> NodeKind {
        if name.fileAttributes & NTFSFileName.directoryFlag != 0 { return .directory }
        if name.fileAttributes & NTFSFileName.reparseFlag != 0, NTFSReparse.isLink(tag: name.reparseTag) {
            return .symlink
        }
        if name.fileAttributes & NTFSInterix.systemFlag != 0,
            let file = try? self.record(record), (try? interixTarget(file)) != nil
        {
            return .symlink
        }
        return .regular
    }

    public func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry {
        let units = Array(String(decoding: name, as: UTF8.self).utf16)
        guard let found = try listing(directory).find(units: units, folded: fold(units)) else { throw .notFound }
        return DirectoryEntry(
            // @dl:accept -- each reader maps its own directory entries to DirectoryEntry; the fields happen to share names
            name: found.fileName.name, id: found.record, kind: kind(found.fileName, record: found.record),
            nextCookie: 0)
    }

    public func entries(of directory: UInt64, from cookie: UInt64, limit: Int) throws(DiskError) -> [DirectoryEntry] {
        let names = try listing(directory).names
        return try DirectoryPage.page(count: names.count, from: cookie, limit: limit) { (position) throws(DiskError) in
            let name = names[position]
            return DirectoryEntry(
                name: name.fileName.name, id: name.record, kind: kind(name.fileName, record: name.record),
                nextCookie: UInt64(position + 1))
        }
    }
}
