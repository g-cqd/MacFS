import MountKit
import Testing

/// Whether a mount asks to write (ADR-0018, roadmap 0046): only by name. Once the modules had a check, Disk Arbitration
/// automounted their writable devices without `rdonly` (`-o nodev,noowners,nosuid,nofollow`), so the absence of `rdonly` asks
/// for nothing. It drops a bare `rw` from its mount arguments but keeps `writable` (measured).
@Suite struct WriteRequestTests {
    @Test func anAutomountsOptionsAskForNothing() {
        #expect(!WriteRequest.asksToWrite(["-o", "nodev,noowners,nosuid,nofollow"]))
        #expect(!WriteRequest.asksToWrite([]))
    }

    @Test func rwOrWritableAsksToWrite() {
        #expect(WriteRequest.asksToWrite(["-o", "rw"]))
        #expect(WriteRequest.asksToWrite(["-o", "writable"]))
        #expect(WriteRequest.asksToWrite(["-o", "nodev,noowners,nosuid,writable,nofollow"]))
        #expect(WriteRequest.asksToWrite(["-f", "-o", "nobrowse", "-o", "rw"]))
    }

    @Test func readOnlyWinsOverAWriteRequest() {
        #expect(!WriteRequest.asksToWrite(["-o", "rw,rdonly"]))
        #expect(!WriteRequest.asksToWrite(["-o", "writable", "-o", "ro"]))
    }

    @Test func onlyAnOptionListCounts() {
        #expect(!WriteRequest.asksToWrite(["rw"]))
        #expect(!WriteRequest.asksToWrite(["-o"]))
        #expect(!WriteRequest.asksToWrite(["-t", "rw"]))
        #expect(!WriteRequest.asksToWrite(["-o", "rwx,writeable"]))
    }
}
