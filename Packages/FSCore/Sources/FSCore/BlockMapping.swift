/// A reader whose files' bytes can be read by the kernel itself (FSKit's kernel-offloaded I/O, roadmap 0018): where each piece
/// of a file lies on the device. A file that is not stored as its bytes (inline, compressed, resident, encrypted) is not
/// mappable and keeps going through `read`.
public protocol BlockMapping: ReadOnlyFileSystem {
    /// Whether every byte of the regular file `id` lies on the device as it reads.
    func isMappable(_ id: UInt64) throws(DiskError) -> Bool
    /// The pieces covering [`offset`, `offset + length`), whole units (blocks, clusters, sectors), up to the file's last unit.
    func blockMap(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange]
    /// Called before the kernel reads a mapped range: a reader with data checksums verifies them here, as Linux verifies a
    /// read from the disk.
    func prepareMappedRead(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError)
}

extension BlockMapping {
    public func prepareMappedRead(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) {}
}
