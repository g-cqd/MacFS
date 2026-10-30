/// XFS's name hash for directories and attributes (`xfs_da_hashname`, fs/xfs/libxfs/xfs_da_btree.c): four bytes at a
/// time, each in its own 7-bit field, XORed into the hash rotated by 28 bits; a tail of one to three bytes the same way.
enum XFSDirectoryHash {
    static func hash(_ name: [UInt8]) -> UInt32 {
        var hash: UInt32 = 0
        var index = 0
        while name.count - index >= 4 {
            hash =
                UInt32(name[index]) << 21 ^ UInt32(name[index + 1]) << 14 ^ UInt32(name[index + 2]) << 7
                ^ UInt32(name[index + 3]) ^ rotated(hash, 28)
            index += 4
        }
        switch name.count - index {
            case 3:
                return UInt32(name[index]) << 14 ^ UInt32(name[index + 1]) << 7 ^ UInt32(name[index + 2])
                    ^ rotated(hash, 21)
            case 2: return UInt32(name[index]) << 7 ^ UInt32(name[index + 1]) ^ rotated(hash, 14)
            case 1: return UInt32(name[index]) ^ rotated(hash, 7)
            default: return hash
        }
    }

    private static func rotated(_ value: UInt32, _ bits: UInt32) -> UInt32 { value << bits | value >> (32 - bits) }
}
