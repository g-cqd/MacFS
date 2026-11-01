/// Writes the kernel makes itself (roadmap 0046): FSKit's kernel-offloaded I/O, Apple's own modules' write path. The module
/// maps a range for writing, the kernel writes the data to the device there, the module completes the write.
public protocol WritableBlockMapping: BlockMapping, WritableFileSystem {
    /// Where the bytes `offset ..< offset + length` of file `id` are to be written, every block of the range stored: blocks
    /// it lacked are allocated, zeroed (a crash before the kernel's write shows zeros, never another file's bytes) and
    /// linked. The size stays until `completeWrite`.
    func mapForWriting(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError) -> [MappedRange]
    /// The kernel wrote `offset ..< offset + length`: the size grows to cover it, the times move.
    func completeWrite(_ id: UInt64, offset: UInt64, length: UInt64) throws(DiskError)
}
