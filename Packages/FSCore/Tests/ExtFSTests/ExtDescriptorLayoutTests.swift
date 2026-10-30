import Testing

@testable import ExtFS

/// Where group descriptors live (roadmap 0016), as Linux's `ext4_bg_has_super` and `descriptor_loc` place them. The images
/// cover meta_bg with and without sparse_super and a volume grown into meta_bg; these cover the rest of the rule.
@Suite struct ExtDescriptorLayoutTests {
    typealias Layout = ExtSuperblock.DescriptorLayout

    static let sparse = Layout(
        blockSize: 1024, descriptorsPerBlock: 16, blocksPerGroup: 1024, firstDataBlock: 1, metaBG: false,
        firstMetaBG: 0,
        sparseSuper: true, sparseSuper2: nil)

    @Test func sparseSuperKeepsBackupsInGroupsOneAndPowersOfThreeFiveAndSeven() {
        let groups = (0 ..< 400).filter { Self.sparse.hasSuperblock(UInt64($0)) }
        #expect(groups == [0, 1, 3, 5, 7, 9, 25, 27, 49, 81, 125, 243, 343])
    }

    @Test func withoutSparseSuperEveryGroupHasOne() {
        var layout = Self.sparse
        layout.sparseSuper = false
        #expect((0 ..< 50).allSatisfy { layout.hasSuperblock(UInt64($0)) })
    }

    @Test func sparseSuper2KeepsGroupZeroAndItsTwoNamedGroups() {
        var layout = Self.sparse
        layout.sparseSuper2 = (1, 40)
        #expect((0 ..< 100).filter { layout.hasSuperblock(UInt64($0)) } == [0, 1, 40])
        layout.sparseSuper2 = (0, 0)
        #expect((0 ..< 100).filter { layout.hasSuperblock(UInt64($0)) } == [0])
    }

    @Test func withoutMetaBGTheTableFollowsTheSuperblock() {
        #expect((0 ..< 4).map { Self.sparse.descriptorBlock($0) } == [2, 3, 4, 5])
        var wide = Self.sparse
        wide.blockSize = 4096
        wide.firstDataBlock = 0
        #expect((0 ..< 3).map { wide.descriptorBlock($0) } == [1, 2, 3])
    }

    @Test func underMetaBGEachMetagroupKeepsItsOwnInItsFirstGroup() {
        var layout = Self.sparse
        layout.metaBG = true
        // Metagroup n starts at group 16n, block 1 + 16n * 1024; group 0 has the superblock, groups 16, 32 and 48 do not.
        #expect((0 ..< 4).map { layout.descriptorBlock($0) } == [2, 16385, 32769, 49153])
        layout.sparseSuper = false
        #expect((0 ..< 4).map { layout.descriptorBlock($0) } == [2, 16386, 32770, 49154])
    }

    @Test func metagroupsBeforeTheFirstMetaBGKeepTheOldTable() {
        var layout = Self.sparse
        layout.metaBG = true
        layout.firstMetaBG = 2
        #expect((0 ..< 4).map { layout.descriptorBlock($0) } == [2, 3, 32769, 49153])
    }

    /// 1 KiB blocks with the data starting at block 0 (bigalloc): the superblock is still in block 1, so group 0's
    /// descriptors are in block 2.
    @Test func oneKiBBlocksFromBlockZeroSkipTheSuperblocksBlock() {
        var layout = Self.sparse
        layout.firstDataBlock = 0
        #expect(layout.descriptorBlock(0) == 2)
        layout.metaBG = true
        #expect(layout.descriptorBlock(0) == 2)
        #expect(layout.descriptorBlock(1) == 16384)
    }
}
