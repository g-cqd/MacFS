import FSCore
import FSKit

extension DiskError {
    /// The POSIX error FSKit hands to the kernel.
    var fskit: any Error { fs_errorForPOSIXError(posixCode) }
}

/// Errors from the module itself rather than from a reader.
enum ModuleError {
    static var readOnly: any Error { fs_errorForPOSIXError(EROFS) }
    static var invalid: any Error { fs_errorForPOSIXError(EINVAL) }
    static var invalidCookie: any Error { fs_errorForPOSIXError(Int32(FSError.Code.invalidDirectoryCookie.rawValue)) }
}
