/// The volume's free blocks and inodes as a writing session left them; the superblock gets them at `close`.
struct ExtFreeCounts: Sendable, Equatable {
    var blocks: UInt64
    var inodes: UInt32
}
