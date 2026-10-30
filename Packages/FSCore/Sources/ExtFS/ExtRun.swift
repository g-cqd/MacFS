/// A range of a file's blocks: `count` blocks from `logical`, at `physical` on disk, or a hole.
struct ExtRun: Sendable, Equatable {
    let logical: UInt64
    let physical: UInt64?
    let count: UInt64

    var end: UInt64 { logical + count }
}
