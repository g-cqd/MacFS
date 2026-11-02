import Darwin
public import FSCore

/// `nfsstat3` values this server answers (RFC 1813 section 2.6).
public enum NFSStatus {
    public static let ok: UInt32 = 0
    public static let noEntry: UInt32 = 2
    public static let io: UInt32 = 5
    public static let exists: UInt32 = 17
    public static let access: UInt32 = 13
    public static let notDirectory: UInt32 = 20
    public static let isDirectory: UInt32 = 21
    public static let invalid: UInt32 = 22
    public static let readOnly: UInt32 = 30
    public static let stale: UInt32 = 70
    public static let badHandle: UInt32 = 10_001
    /// NFS3ERR_NOT_SYNC: a SETATTR's guard did not match the change time.
    public static let notSynchronized: UInt32 = 10_002
    public static let badCookie: UInt32 = 10_003
    public static let notSupported: UInt32 = 10_004

    /// RFC 1813 numbers its statuses after the POSIX errors (NOENT 2, IO 5, ACCES 13, NOTDIR 20, ISDIR 21, INVAL 22, ROFS 30),
    /// but for NFS3ERR_NOTSUPP: so the error's POSIX code is its status.
    public static func of(_ error: DiskError) -> UInt32 {
        error.posixCode == ENOTSUP ? notSupported : UInt32(error.posixCode)
    }
}
