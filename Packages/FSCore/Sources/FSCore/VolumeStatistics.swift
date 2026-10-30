/// Space and file counts, as `statfs` reports them.
public struct VolumeStatistics: Sendable, Equatable {
    public var blockSize: Int
    public var totalBlocks: UInt64
    public var freeBlocks: UInt64
    public var files: UInt64

    public init(blockSize: Int, totalBlocks: UInt64, freeBlocks: UInt64, files: UInt64) {
        self.blockSize = blockSize
        self.totalBlocks = totalBlocks
        self.freeBlocks = freeBlocks
        self.files = files
    }
}
