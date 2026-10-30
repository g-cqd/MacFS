/// Item types and well-known object identifiers this reader uses (`fs/btrfs/accessors.h`, `uapi/linux/btrfs_tree.h`).
// @dl:accept -- a table of on-disk constants; its shape is shared with every other format's table
enum BtrfsItem {
    static let inode: UInt8 = 1
    static let inodeRef: UInt8 = 12
    static let dirItem: UInt8 = 84
    static let dirIndex: UInt8 = 96
    static let extentData: UInt8 = 108
    static let rootItem: UInt8 = 132
    static let rootBackref: UInt8 = 144
    static let chunkItem: UInt8 = 228

    static let fsTree: UInt64 = 5
    static let rootDirectoryObject: UInt64 = 6
    static let firstChunkTreeObject: UInt64 = 256
    static let firstFreeObject: UInt64 = 256
}
