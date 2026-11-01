import FSCore
import Testing

@testable import ExtFS

// Extent nodes built by hand from the on-disk layout, for the cases mke2fs never writes:
// unwritten extents, index nodes, and the corruptions a hostile image can carry.
@Suite struct ExtExtentTreeTests {
    static func node(depth: UInt16, _ entries: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = [0x0A, 0xF3]
        bytes += le16(UInt16(entries.count)) + le16(4) + le16(depth) + [0, 0, 0, 0]
        for entry in entries { bytes += entry }
        return bytes + [UInt8](repeating: 0, count: max(0, 60 - bytes.count))
    }

    static func leaf(logical: UInt32, length: UInt16, start: UInt64) -> [UInt8] {
        le32(logical) + le16(length) + le16(UInt16(start >> 32)) + le32(UInt32(truncatingIfNeeded: start))
    }

    static func index(logical: UInt32, child: UInt64) -> [UInt8] {
        le32(logical) + le32(UInt32(truncatingIfNeeded: child)) + le16(UInt16(child >> 32)) + [0, 0]
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    @Test func unwrittenExtentsAreHoles() throws {
        let root = Self.node(
            depth: 0,
            [Self.leaf(logical: 0, length: 4, start: 100), Self.leaf(logical: 4, length: 32768 + 6, start: 200)]
        )
        let runs = try ExtExtentTree.runs(DiskBytes(root), number: 12) { (_) throws(DiskError) -> DiskBytes in
            throw .notFound
        }
        #expect(runs == [ExtRun(logical: 0, physical: 100, count: 4), ExtRun(logical: 4, physical: nil, count: 6)])
    }

    /// EXT_INIT_MAX_LEN: 32768 is the longest written extent; 32769 is the shortest unwritten one.
    @Test func theUnwrittenBoundary() throws {
        let root = Self.node(
            depth: 0,
            [Self.leaf(logical: 0, length: 32768, start: 100), Self.leaf(logical: 32768, length: 32769, start: 200)]
        )
        let runs = try ExtExtentTree.runs(DiskBytes(root), number: 12) { (_) throws(DiskError) -> DiskBytes in
            throw .notFound
        }
        #expect(
            runs == [ExtRun(logical: 0, physical: 100, count: 32768), ExtRun(logical: 32768, physical: nil, count: 1)]
        )
    }

    @Test func indexNodesAreFollowedInOrder() throws {
        let children: [UInt64: [UInt8]] = [
            0x1_0000_0001: Self.node(depth: 0, [Self.leaf(logical: 0, length: 2, start: 7)]),
            5: Self.node(depth: 0, [Self.leaf(logical: 10, length: 1, start: 0x2_0000_0009)])
        ]
        let root = Self.node(
            depth: 1,
            [Self.index(logical: 0, child: 0x1_0000_0001), Self.index(logical: 10, child: 5)]
        )
        let runs = try ExtExtentTree.runs(DiskBytes(root), number: 12) { (block) throws(DiskError) -> DiskBytes in
            guard let bytes = children[block] else { throw .notFound }
            return DiskBytes(bytes)
        }
        #expect(
            runs == [ExtRun(logical: 0, physical: 7, count: 2), ExtRun(logical: 10, physical: 0x2_0000_0009, count: 1)]
        )
    }

    @Test func aChildAtTheWrongDepthIsCorrupt() {
        let root = Self.node(depth: 2, [Self.index(logical: 0, child: 1)])
        #expect(throws: DiskError.self) {
            try ExtExtentTree.runs(DiskBytes(root), number: 12) { (_) throws(DiskError) -> DiskBytes in
                DiskBytes(Self.node(depth: 0, []))
            }
        }
    }

    @Test func overlappingExtentsAreCorrupt() {
        let root = Self.node(
            depth: 0,
            [Self.leaf(logical: 0, length: 4, start: 1), Self.leaf(logical: 3, length: 1, start: 9)]
        )
        #expect(throws: DiskError.self) {
            try ExtExtentTree.runs(DiskBytes(root), number: 12) { (_) throws(DiskError) -> DiskBytes in throw .notFound
            }
        }
    }

    @Test func aSelfReferencingTreeTerminates() {
        // A node that points at itself as its own child, at a depth that keeps the check satisfied, cannot
        // loop: each level must be one below its parent, so the walk ends after five levels.
        let root = Self.node(depth: 5, [Self.index(logical: 0, child: 1)])
        #expect(throws: DiskError.self) {
            try ExtExtentTree.runs(DiskBytes(root), number: 12) { (_) throws(DiskError) -> DiskBytes in DiskBytes(root)
            }
        }
    }
}
