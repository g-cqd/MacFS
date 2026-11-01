import FSCore
import NFSProxy
import Testing

/// A write refused because the volume is read-only answers NFS3ERR_ROFS, as RFC 1813 names it (ADR-0018).
struct NFSStatusTests {
    /// Every error's status, as RFC 1813 numbers them: the POSIX number, but for NFS3ERR_NOTSUPP.
    @Test(arguments: [
        (DiskError.notFound, UInt32(2)), (.notDirectory, 20), (.isDirectory, 21), (.accessDenied("x"), 13),
        (.unsupported("x"), 10_004), (.notSymlink, 22), (.corrupt("x"), 5), (.checksum("x"), 5),
        (.io(errno: 9, "x"), 5),
        (.readOnly, 30), (.noSpace, 28), (.exists, 17), (.notEmpty, 66), (.nameTooLong, 63), (.invalidName, 22)
    ])
    func eachErrorHasItsStatus(error: DiskError, status: UInt32) {
        #expect(NFSStatus.of(error) == status)
    }

    @Test func aReadOnlyRefusalIsROFS() {
        #expect(NFSStatus.of(.readOnly) == 30)
        #expect(NFSStatus.of(.readOnly) == NFSStatus.readOnly)
    }
}
