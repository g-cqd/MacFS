import FSCore

/// Interix special files, as ntfs-3g writes and reads them (`ntfs_get_interix_type` in libntfs-3g): a file with the system
/// attribute whose unnamed data starts with a type tag. Only symbolic links are read; device tags read as plain files.
enum NTFSInterix {
    static let systemFlag: UInt32 = 0x0004
    static let linkMagic: [UInt8] = Array("IntxLNK".utf8) + [1]
    /// Larger data is not a link (ntfs-3g's limit is PATH_MAX in UTF-16).
    static let largestLink = 8 + 2 * 4096

    /// The target of a link's data, or nil when the data is not a link.
    static func linkTarget(_ data: [UInt8]) throws(DiskError) -> [UInt8]? {
        guard data.count >= linkMagic.count, data.starts(with: linkMagic) else { return nil }
        let target = data.count - linkMagic.count
        guard target % 2 == 0 else { throw .corrupt("Interix link with an odd-length target") }
        return UTF16Name.utf8(try DiskBytes(data).slice(linkMagic.count, target))
    }
}
