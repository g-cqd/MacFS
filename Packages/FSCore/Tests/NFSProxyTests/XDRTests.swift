import NFSProxy
import Testing

// XDR (RFC 4506) and record marking (RFC 5531 section 11), against bytes worked by hand.
@Suite struct XDRTests {
    @Test func integersAreBigEndianAndOpaquePadsToFourBytes() throws {
        var writer = XDRWriter()
        writer.u32(0x0102_0304)
        writer.u64(0x0506_0708_090A_0B0C)
        writer.bool(true)
        writer.opaque([0xAA, 0xBB, 0xCC])
        writer.string("hi")
        #expect(
            writer.bytes == [
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, 0, 0, 1, 0, 0, 0, 3, 0xAA, 0xBB, 0xCC, 0, 0, 0, 0, 2, 0x68,
                0x69, 0, 0
            ]
        )
        var reader = XDRReader(writer.bytes)
        #expect(try reader.u32() == 0x0102_0304)
        #expect(try reader.u64() == 0x0506_0708_090A_0B0C)
        #expect(try reader.bool())
        #expect(try reader.opaque(maximum: 8) == [0xAA, 0xBB, 0xCC])
        #expect(try reader.opaque(maximum: 8) == Array("hi".utf8))
        #expect(reader.remaining == 0)
    }

    @Test func truncatedAndOversizedInputsThrow() {
        var short = XDRReader([0, 0, 1])
        #expect(throws: XDRError.self) { try short.u32() }
        var long = XDRReader([0, 0, 0, 9, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0])
        #expect(throws: XDRError.self) { try long.opaque(maximum: 8) }
        var lying = XDRReader([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: XDRError.self) { try lying.opaque(maximum: 1 << 20) }
    }

    @Test func recordMarkingJoinsFragmentsAndWaitsForTheLast() throws {
        var reader = RecordReader(maximum: 1 << 20)
        reader.append([0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB])  // fragment of 2, not last
        #expect(try reader.next() == nil)
        reader.append([0x80, 0x00, 0x00, 0x01])
        #expect(try reader.next() == nil, "the last fragment's byte has not arrived")
        reader.append([0xCC, 0x80, 0x00, 0x00, 0x00])
        #expect(try reader.next() == [0xAA, 0xBB, 0xCC])
        #expect(try reader.next() == [], "an empty last fragment is an empty record")
        #expect(RecordReader.frame([1, 2]) == [0x80, 0, 0, 2, 1, 2])
    }

    @Test func aRecordLargerThanTheLimitIsRefused() {
        var reader = RecordReader(maximum: 16)
        reader.append([0x80, 0x00, 0x01, 0x00])
        #expect(throws: XDRError.self) { try reader.next() }
    }
}
