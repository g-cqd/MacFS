/// A volume that also takes changes (ADR-0018): the seam every mount path writes through. Grows with each slice of the
/// writers (roadmap 0026): today, overwriting a file's bytes.
public protocol WritableFileSystem: ReadOnlyFileSystem {
    /// `bytes` into file `id` at `offset`.
    func write(_ id: UInt64, at offset: UInt64, _ bytes: [UInt8]) throws(DiskError)
    /// Every change so far made durable.
    func synchronize() throws(DiskError)
    /// The unmount: changes made durable and the volume left clean. No change is accepted after it.
    func close() throws(DiskError)
}
