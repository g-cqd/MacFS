import FSCore

/// One on-disk inode (`struct ext4_inode`).
struct ExtInode: Sendable {
    static let indexFlag: UInt32 = 0x0000_1000
    static let encryptedFlag: UInt32 = 0x0000_0800
    static let hugeFileFlag: UInt32 = 0x0004_0000
    static let extentsFlag: UInt32 = 0x0008_0000
    static let inlineDataFlag: UInt32 = 0x1000_0000

    let number: UInt64
    let raw: DiskBytes
    let mode: UInt16
    let flags: UInt32
    let size: UInt64
    let linkCount: UInt16
    let uid: UInt32
    let gid: UInt32
    /// Blocks in 512-byte units (file system blocks with the huge-file flag).
    let sectors: UInt64
    let xattrBlock: UInt64
    /// The 60 bytes of `i_block`: block pointers, an extent tree, inline data or a fast symlink.
    let blockArea: DiskBytes
    let extraSize: Int
    let generation: UInt32
    private let checksums: ExtChecksums?

    init(_ raw: DiskBytes, number: UInt64, checksums: ExtChecksums? = nil) throws(DiskError) {
        self.number = number
        self.raw = raw
        mode = try raw.u16(0x00)
        uid = try raw.u32(low16: 0x02, high16: 0x78)
        size = try raw.u64(low32: 0x04, high32: 0x6C)
        gid = try raw.u32(low16: 0x18, high16: 0x7A)
        linkCount = try raw.u16(0x1A)
        flags = try raw.u32(0x20)
        sectors = try raw.u64(low32: 0x1C, high16: 0x74)
        xattrBlock = try raw.u64(low32: 0x68, high16: 0x76)
        blockArea = try raw.slice(0x28, 60)
        extraSize = raw.count > 128 ? Int(try raw.u16(0x80)) : 0
        guard 128 + extraSize <= raw.count else { throw .corrupt("inode \(number): extra size \(extraSize)") }
        generation = try raw.u32(0x64)
        self.checksums = checksums
    }

    var kind: NodeKind { NodeKind(posixMode: UInt32(mode)) }

    /// The seed of this inode's block checksums (extent and directory blocks), when the volume has them. Computed when a
    /// block needs it: most inode reads need none.
    var checksumSeed: UInt32? { checksums?.inodeSeed(number: number, generation: generation) }

    /// A time field with its `_extra` word: two epoch bits extend the seconds, thirty bits hold nanoseconds.
    func time(_ offset: Int, extra: Int?) throws(DiskError) -> Timestamp {
        var seconds = Int64(Int32(bitPattern: try raw.u32(offset)))
        var nanoseconds: Int32 = 0
        if let extra, 128 + extraSize >= extra + 4 {
            let word = try raw.u32(extra)
            seconds += Int64(word & 3) << 32
            nanoseconds = Int32(clamping: (word >> 2) % 1_000_000_000)
        }
        return Timestamp(seconds: seconds, nanoseconds: nanoseconds)
    }
}
