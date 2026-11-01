/// MOUNT version 3 (RFC 1813 appendix I): one export, its secret path, mounted once (roadmap 0038); none listed.
enum MountProgram {
    static let number: UInt32 = 100_005

    /// `admit` is asked once the path matches: true for the first MNT only.
    static func handle(
        _ procedure: UInt32,
        _ arguments: inout XDRReader,
        export: NFSExport,
        root: [UInt8],
        admit: () -> Bool
    ) throws(XDRError) -> XDRWriter? {
        var results = XDRWriter()
        switch procedure {
            case 0, 3, 4:  // NULL, UMNT, UMNTALL
                if procedure == 3 { _ = try arguments.opaque(maximum: 1024) }
            case 1:  // MNT
                let path = try arguments.string(maximum: 1024)
                guard path == export.path else {
                    results.u32(2)  // MNT3ERR_NOENT
                    return results
                }
                guard admit() else {
                    results.u32(13)  // MNT3ERR_ACCES: mounted already, and the path is in the mount table now
                    return results
                }
                results.u32(0)
                results.opaque(root)
                results.u32(1)  // one flavor: AUTH_UNIX
                results.u32(1)
            case 2:  // DUMP: no list kept
                results.bool(false)
            case 5:  // EXPORT: none listed, so the path is not given away
                results.bool(false)
            default:
                return nil
        }
        return results
    }
}
