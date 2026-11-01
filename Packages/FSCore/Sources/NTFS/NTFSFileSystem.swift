import AemiKernel
public import FSCore

/// A read-only NTFS volume (NTFS 3.x, Windows XP and later).
///
/// Node identifiers are MFT record numbers; the root directory is record 5. System files (records
/// below 24) are never listed.
public final class NTFSFileSystem: ReadOnlyFileSystem {
    public let volume: VolumeDescription
    public let rootID: UInt64 = 5
    static let firstUserRecord: UInt64 = 24

    let source: any BlockSource
    let boot: NTFSBoot
    private let mft: NTFSStream
    let upcase: [UInt16]
    private let records = BoundedCache<UInt64, NTFSRecord>(capacity: 4096)
    let listings = BoundedCache<UInt64, NTFSListing>(capacity: 256)
    let freeClusters = BoundedCache<Int, UInt64>(capacity: 2)

    public static func probe(_ source: any BlockSource) -> Bool {
        (try? source.read(at: 0, count: 512)).map(NTFSBoot.looksLikeOne) ?? false
    }

    public init(source: any BlockSource) throws(DiskError) {
        self.source = source
        boot = try NTFSBoot(try source.read(at: 0, count: 512))
        // Record 0 describes the MFT itself; its first extent is enough to find any extension record.
        let selfRecord = try NTFSRecord(
            try source.read(at: boot.mftCluster * UInt64(boot.clusterSize), count: boot.recordSize),
            number: 0
        )
        let bootstrap = try NTFSStream(selfRecord.extents(NTFSAttributeType.data), clusterSize: boot.clusterSize)
        let full = try Self.withAttributeList(selfRecord, source: source, boot: boot, mft: bootstrap)
        mft = try NTFSStream(full.extents(NTFSAttributeType.data), clusterSize: boot.clusterSize)
        upcase = Self.loadUpcase(source: source, boot: boot, mft: mft)
        let volumeRecord = try Self.load(3, source: source, boot: boot, mft: mft)
        let label = volumeRecord.first(NTFSAttributeType.volumeName)?.value.map(UTF16Name.utf8) ?? []
        var uuid = [UInt8](repeating: 0, count: 16)
        for index in 0 ..< 8 { uuid[index] = UInt8(truncatingIfNeeded: boot.serial >> (8 * index)) }
        volume = VolumeDescription(
            format: "ntfsro",
            label: String(decoding: label, as: UTF8.self),
            uuid: uuid,
            caseRule: .insensitivePreserving,
            maximumNameLength: 255
        )
    }

    // MARK: Records

    static func load(_ number: UInt64, source: any BlockSource, boot: NTFSBoot, mft: NTFSStream) throws(DiskError)
        -> NTFSRecord
    {
        let size = boot.recordSize
        guard let offset = number.checkedMultiplied(by: UInt64(size)), offset < mft.size else { throw .notFound }
        let raw = try mft.read(source, at: offset, count: size)
        guard raw.count == size else { throw .corrupt("MFT record \(number) is cut short") }
        return try NTFSRecord(raw, number: number)
    }

    /// The record with the attributes its `$ATTRIBUTE_LIST` places in extension records merged in.
    static func withAttributeList(
        _ record: NTFSRecord,
        source: any BlockSource,
        boot: NTFSBoot,
        mft: NTFSStream
    ) throws(DiskError) -> NTFSRecord {
        guard let list = record.first(NTFSAttributeType.attributeList) else { return record }
        let content = try NTFSStream([list], clusterSize: boot.clusterSize)
        let bytes = DiskBytes(try content.read(source, at: 0, count: Int(min(content.size, 1 << 20))))
        var extensions: [UInt64] = []
        var cursor = 0
        while cursor + 26 <= bytes.count {
            let length = Int(try bytes.u16(cursor + 4))
            guard length >= 26 else { throw .corrupt("attribute list entry of \(length) bytes") }
            let reference = try bytes.u64(cursor + 16) & 0xFFFF_FFFF_FFFF
            if reference != record.number, !extensions.contains(reference) { extensions.append(reference) }
            cursor += length
        }
        var merged = record
        for number in extensions.prefix(1024) {
            let part = try load(number, source: source, boot: boot, mft: mft)
            guard part.base == record.number else {
                throw .corrupt("record \(number) extends \(part.base), not \(record.number)")
            }
            merged.attributes += part.attributes.filter { $0.type != NTFSAttributeType.attributeList }
        }
        return merged
    }

    /// A base record in use, with its attribute list resolved; cached.
    func record(_ number: UInt64) throws(DiskError) -> NTFSRecord {
        try records.value(for: number) { () throws(DiskError) -> NTFSRecord in
            let record = try Self.load(number, source: source, boot: boot, mft: mft)
            guard record.flags & NTFSRecord.inUse != 0, record.base == 0 else { throw .notFound }
            return try Self.withAttributeList(record, source: source, boot: boot, mft: mft)
        }
    }

    func stream(_ record: NTFSRecord, _ type: UInt32, named name: [UInt8] = []) throws(DiskError) -> NTFSStream {
        try NTFSStream(record.extents(type, named: name), clusterSize: boot.clusterSize)
    }

    /// `$UpCase` (record 10): the upper-case form of every UTF-16 unit, as Windows folds names.
    private static func loadUpcase(source: any BlockSource, boot: NTFSBoot, mft: NTFSStream) -> [UInt16] {
        let ascii = (0 ..< UInt16(128)).map { (0x61 ... 0x7A).contains($0) ? $0 - 0x20 : $0 }
        guard let record = try? load(10, source: source, boot: boot, mft: mft),
            let stream = try? NTFSStream(record.extents(NTFSAttributeType.data), clusterSize: boot.clusterSize),
            stream.size == 131_072, let raw = try? stream.read(source, at: 0, count: 131_072)
        else { return ascii }
        let bytes = DiskBytes(raw)
        return (0 ..< 65_536).map { (try? bytes.u16(2 * $0)) ?? UInt16($0) }
    }

    func fold(_ units: [UInt16]) -> [UInt16] {
        units.map { Int($0) < upcase.count ? upcase[Int($0)] : $0 }
    }

    public func statistics() throws(DiskError) -> VolumeStatistics {
        let total = boot.totalClusters
        let free = try freeClusters.value(for: 0) { () throws(DiskError) -> UInt64 in
            let bitmap = try stream(try record(6), NTFSAttributeType.data)
            let bytes = Int(min(bitmap.size, (total + 7) / 8))
            var used: UInt64 = 0
            var offset = 0
            while offset < bytes {
                let chunk = try bitmap.read(source, at: UInt64(offset), count: min(1 << 20, bytes - offset))
                used += BitCount.ones(in: chunk)
                offset += chunk.count
                if chunk.isEmpty { break }
            }
            return total > used ? total - used : 0
        }
        return VolumeStatistics(
            blockSize: boot.clusterSize,
            totalBlocks: total,
            freeBlocks: free,
            files: mft.size / UInt64(boot.recordSize)
        )
    }
}
