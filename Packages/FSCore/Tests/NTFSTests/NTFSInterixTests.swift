import FSCore
import Testing

@testable import NTFS

/// Interix symbolic links (what ntfs-3g writes by default, and Services for UNIX before it): a system file whose data is
/// `IntxLNK\1` and the target in UTF-16LE. ntfs-3g's `ntfs_get_interix_type` is the reference.
@Suite struct NTFSInterixTests {
    static func data(_ target: String) -> [UInt8] {
        Array("IntxLNK".utf8) + [1] + target.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    @Test func aLinkIsItsMagicThenItsTarget() throws {
        #expect(try NTFSInterix.linkTarget(Self.data("../hello.txt")) == Array("../hello.txt".utf8))
        #expect(try NTFSInterix.linkTarget(Self.data("naïve/日本")) == Array("naïve/日本".utf8))
    }

    @Test func otherDataIsNotALink() throws {
        #expect(try NTFSInterix.linkTarget(Array("IntxCHR".utf8) + [0, 1, 2]) == nil)
        #expect(try NTFSInterix.linkTarget(Array("hello".utf8)) == nil)
        #expect(try NTFSInterix.linkTarget([]) == nil)
    }

    @Test func anOddLengthTargetIsCorrupt() {
        #expect(throws: DiskError.self) { try NTFSInterix.linkTarget(Self.data("ab") + [0x41]) }
    }
}
