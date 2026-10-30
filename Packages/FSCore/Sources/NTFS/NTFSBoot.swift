import AemiKernel
import FSCore

/// The NTFS boot sector (BIOS parameter block) fields the reader needs.
struct NTFSBoot: Sendable {
    static let oem: [UInt8] = Array("NTFS    ".utf8)

    let bytesPerSector: Int
    let clusterSize: Int
    let totalSectors: UInt64
    let mftCluster: UInt64
    let recordSize: Int
    let indexBlockSize: Int
    let serial: UInt64

    static func looksLikeOne(_ bytes: [UInt8]) -> Bool {
        let view = DiskBytes(bytes)
        return view.matches(oem, at: 3) && view.matches([0x55, 0xAA], at: 510)
    }

    init(_ raw: [UInt8]) throws(DiskError) {
        let bytes = DiskBytes(raw)
        guard Self.looksLikeOne(raw) else { throw .corrupt("no NTFS boot sector") }
        bytesPerSector = Int(try bytes.u16(0x0B))
        guard [512, 1024, 2048, 4096].contains(bytesPerSector) else {
            throw .corrupt("\(bytesPerSector) bytes per sector")
        }
        let perCluster = try bytes.u8(0x0D)
        // Values above 0x80 are negative powers of two (clusters above 64 KiB, Windows 10 1709 and later).
        let sectors = perCluster <= 0x80 ? Int(perCluster) : 1 << (256 - Int(perCluster))
        guard sectors > 0, sectors.nonzeroBitCount == 1, sectors * bytesPerSector <= 2 << 20 else {
            throw .corrupt("\(perCluster) sectors per cluster")
        }
        clusterSize = sectors * bytesPerSector
        totalSectors = try bytes.u64(0x28)
        mftCluster = try bytes.u64(0x30)
        recordSize = try Self.size(try bytes.i8(0x40), clusterSize: clusterSize)
        indexBlockSize = try Self.size(try bytes.i8(0x44), clusterSize: clusterSize)
        serial = try bytes.u64(0x48)
        guard mftCluster.checkedMultiplied(by: UInt64(clusterSize)) != nil else {
            throw .corrupt("MFT cluster \(mftCluster)")
        }
    }

    /// A count of clusters, or, when negative, 2^-value bytes.
    private static func size(_ value: Int8, clusterSize: Int) throws(DiskError) -> Int {
        let size = value > 0 ? Int(value) * clusterSize : value < 0 && value >= -24 ? 1 << -Int(value) : 0
        guard size >= 512, size <= 1 << 16, size.nonzeroBitCount == 1 else {
            throw .corrupt("record size code \(value)")
        }
        return size
    }

    var totalClusters: UInt64 { totalSectors * UInt64(bytesPerSector) / UInt64(clusterSize) }
}
