import Darwin

/// Why a file system could not answer.
///
/// Every case maps to one POSIX code, which is what FSKit, NFS and WebDAV all hand back to the kernel
/// or the client. The string says where: it reaches logs, never a user dialog.
public enum DiskError: Error, Equatable, Sendable {
    /// An on-disk structure contradicts the format: a bad offset, a loop, an impossible length.
    case corrupt(String)
    /// A checksum did not match the bytes it covers.
    case checksum(String)
    /// The format allows it, this reader does not implement it yet (a compression, a RAID profile).
    case unsupported(String)
    /// Encrypted content, or anything else the reader must refuse to hand out.
    case accessDenied(String)
    /// The device failed underneath us.
    case io(errno: Int32, String)
    case notFound
    case notDirectory
    case isDirectory
    case notSymlink
    /// A write to a volume, or a device, opened read-only (ADR-0018).
    case readOnly
    /// No free block or inode left for a change.
    case noSpace

    public var posixCode: Int32 {
        switch self {
            case .corrupt, .checksum, .io: EIO
            case .unsupported: ENOTSUP
            case .accessDenied: EACCES
            case .notFound: ENOENT
            case .notDirectory: ENOTDIR
            case .isDirectory: EISDIR
            case .notSymlink: EINVAL
            case .readOnly: EROFS
            case .noSpace: ENOSPC
        }
    }
}
