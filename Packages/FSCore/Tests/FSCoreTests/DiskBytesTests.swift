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
}
