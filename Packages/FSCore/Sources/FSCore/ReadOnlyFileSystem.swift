/// A mounted, read-only view of one volume.
///
/// The seam every mount technology sits on: FSKit, the loopback proxies, the in-app browser and
/// `fsprobe` all call these methods and nothing below them. Calls are synchronous, safe from any
/// thread, and may block on device reads.
public protocol ReadOnlyFileSystem: Sendable {
    var volume: VolumeDescription { get }
    var rootID: UInt64 { get }

    func statistics() throws(DiskError) -> VolumeStatistics
    func attributes(of id: UInt64) throws(DiskError) -> NodeAttributes

    /// The entry named `name` (UTF-8 bytes) in `directory`, or ``DiskError/notFound``.
    func lookup(_ name: [UInt8], in directory: UInt64) throws(DiskError) -> DirectoryEntry

    /// Up to `limit` entries of `directory`, starting at `cookie` (0 is the first entry). `.` and `..`
    /// are not included: each mount technology adds them its own way.
    func entries(of directory: UInt64, from cookie: UInt64, limit: Int) throws(DiskError) -> [DirectoryEntry]

    /// Up to `count` bytes of `id` from `offset`; fewer only at end of file.
    func read(_ id: UInt64, at offset: UInt64, count: Int) throws(DiskError) -> [UInt8]

    /// The target of a symbolic link, as stored.
    func readLink(_ id: UInt64) throws(DiskError) -> [UInt8]
}
