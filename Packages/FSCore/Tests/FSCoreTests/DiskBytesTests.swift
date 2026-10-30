import FSCore
import Testing

/// `DiskBytes.region`: a bounds-checked view of bytes for checksums, without a copy.
@Suite struct DiskBytesTests {
    @Test func aRegionIsTheBytesAtItsOffsetWithinTheView() throws {
        let bytes = try DiskBytes(Array(0 ..< 64)).slice(8, 32)
        #expect(Array(try bytes.region(4, 6)) == [12, 13, 14, 15, 16, 17])
        #expect(try bytes.region(0, 0).isEmpty)
        #expect(Array(try bytes.region(26, 6)) == [34, 35, 36, 37, 38, 39])
    }

    @Test func aRegionOutsideTheViewThrows() {
        let bytes = DiskBytes([1, 2, 3, 4])
        #expect(throws: DiskError.self) { try bytes.region(2, 3) }
        #expect(throws: DiskError.self) { try bytes.region(-1, 1) }
        #expect(throws: DiskError.self) { try bytes.region(0, -1) }
    }

    /// Big-endian fields (XFS, roadmap 0031), within a view and bounds-checked like the little-endian ones.
    @Test func bigEndianFieldsReadMostSignificantByteFirst() throws {
        let bytes = try DiskBytes(Array(0 ..< 32)).slice(4, 16)
        #expect(try bytes.be16(0) == 0x0405)
        #expect(try bytes.be32(1) == 0x0506_0708)
        #expect(try bytes.be64(8) == 0x0C0D_0E0F_1011_1213)
        #expect(try bytes.u16(0) == 0x0504, "the little-endian read of the same bytes")
        #expect(throws: DiskError.self) { try bytes.be64(9) }
        #expect(throws: DiskError.self) { try bytes.be16(15) }
    }
}
