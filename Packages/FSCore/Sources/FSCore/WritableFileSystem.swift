/// A volume that also takes changes (ADR-0018): the seam every mount path writes through. Grows with each slice of the
/// writers (roadmap 0026): writing files, creating and removing names.
public protocol WritableFileSystem: ReadOnlyFileSystem {
    /// A new, empty file or directory named `name` in `directory`, owned by `owner` with permissions `mode`; its identifier.
    func create(
        _ name: [UInt8],
        kind: NodeKind,
        in directory: UInt64,
        mode: UInt16,
        owner: (uid: UInt32, gid: UInt32)
    ) throws(DiskError) -> UInt64
    /// The name `name` removed from `directory`; the node with it, once it has no name left. A directory must be empty.
    func remove(_ name: [UInt8], from directory: UInt64) throws(DiskError)
    /// `bytes` into file `id` at `offset`.
    func write(_ id: UInt64, at offset: UInt64, _ bytes: [UInt8]) throws(DiskError)
    /// Every change so far made durable.
    func synchronize() throws(DiskError)
    /// The unmount: changes made durable and the volume left clean. No change is accepted after it.
    func close() throws(DiskError)
}
