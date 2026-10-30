import CFSKernels
import Darwin
import FSCore
import Testing

/// Every kernel input ends exactly at a page the process may not touch: one byte read past the end is a crash,
/// which no result comparison could show.
@Suite struct GuardPageTests {
    /// `count` bytes ending at the last byte before a PROT_NONE page.
    static func guarded(_ count: Int, _ body: (UnsafeMutablePointer<UInt8>) -> Void) {
        let page = Int(getpagesize())
        let pages = (count + page - 1) / page + 1
        let base = mmap(nil, (pages + 1) * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        precondition(base != MAP_FAILED)
        defer { munmap(base, (pages + 1) * page) }
        let start = base!.assumingMemoryBound(to: UInt8.self)
        precondition(mprotect(start + pages * page, page, PROT_NONE) == 0)
        let data = start + pages * page - count
        for index in 0 ..< count { data[index] = UInt8(truncatingIfNeeded: index &* 131 &+ 17) }
        body(data)
    }

    @Test func crcNeverReadsPastTheEnd() {
        for count in Array(0 ... 600) + [767, 768, 769, 1023, 3071, 3072, 3073, 4064, 4096, 9000] {
            Self.guarded(count) { data in
                let expected = referenceCRC(7, data, count)
                #expect(fsk_crc32c_update(7, data, count) == expected, "\(count)")
            }
        }
    }

    @Test func popcountAndNarrowingNeverReadPastTheEnd() {
        for count in Array(0 ... 200) + [1024, 4097] {
            Self.guarded(count) { data in
                #expect(fsk_popcount(data, count) == referencePopcount(data, count))
                var ascii = [UInt8](repeating: 0, count: count / 2 + 1)
                _ = ascii.withUnsafeMutableBufferPointer { fsk_utf16le_ascii_prefix(data, count / 2, $0.baseAddress) }
            }
        }
    }
}
