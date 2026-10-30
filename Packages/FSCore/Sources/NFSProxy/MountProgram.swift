/// MOUNT version 3 (RFC 1813 appendix I): one export, "/", for any caller.
enum MountProgram {
    static let number: UInt32 = 100_005

    static func handle(_ procedure: UInt32, _ arguments: inout XDRReader, root: [UInt8]) throws(XDRError) -> XDRWriter?
    {
        var results = XDRWriter()
        switch procedure {
            case 0, 3, 4:  // NULL, UMNT, UMNTALL
                if procedure == 3 { _ = try arguments.opaque(maximum: 1024) }
            case 1:  // MNT
                let path = try arguments.string(maximum: 1024)
                guard path == "/" || path.isEmpty else {
                    results.u32(2)  // MNT3ERR_NOENT
                    return results
                }
                results.u32(0)
                results.opaque(root)
                results.u32(1)  // one flavor: AUTH_UNIX
                results.u32(1)
            case 2:  // DUMP: no list kept
                results.bool(false)
            case 5:  // EXPORT
                results.bool(true)
                results.string("/")
                results.bool(false)  // no group restriction
                results.bool(false)
            default:
                return nil
        }
        return results
    }
}
