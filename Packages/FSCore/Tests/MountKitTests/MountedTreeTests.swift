import FSCore
import MountKit
import Testing

@Suite struct MountedTreeTests {
    /// FSKit and NFS reserve small identifiers: 1 is the root's parent, 2 the root.
    @Test(arguments: [UInt64(2), 5, 256])
    func theRootIsAlwaysTwoAndOtherIdentifiersPassThrough(_ root: UInt64) throws {
        let tree = try MountedTree(InMemoryFileSystem(root: root, files: 3))
        #expect(tree.mountID(for: root) == 2)
        #expect(tree.readerID(for: 2) == root)
        #expect(tree.mountID(for: 1000) == 1000)
        #expect(tree.readerID(for: 1000) == 1000)
        #expect(tree.parentMountID(of: try tree.fileSystem.attributes(of: root)) == 1)
        #expect(tree.parentMountID(of: try tree.fileSystem.attributes(of: 1000)) == 2)
    }

    @Test func aReaderIdentifierThatCollidesWithAReservedOneIsRefused() throws {
        let tree = try MountedTree(InMemoryFileSystem(root: 5, files: 0))
        #expect(throws: DiskError.self) { try tree.checkedMountID(for: 2) }
        #expect(throws: DiskError.self) { try tree.checkedMountID(for: 1) }
        #expect(throws: DiskError.self) { try tree.checkedMountID(for: 0) }
    }

    @Test func pagesWithDotsResumeExactlyAndEndCleanly() throws {
        let tree = try MountedTree(InMemoryFileSystem(root: 5, files: 10))
        var names: [String] = []
        var cookie: UInt64 = 0
        var calls = 0
        while true {
            calls += 1
            let page = try tree.page(of: 2, from: cookie, includeDots: true, limit: 3)
            names += page.map(\.displayName)
            guard let last = page.last else { break }
            cookie = last.nextCookie
        }
        #expect(names == [".", ".."] + (0 ..< 10).map { "f\($0)" })
        #expect(calls == 5)
    }

    @Test func dotsPointAtTheDirectoryAndItsParent() throws {
        let tree = try MountedTree(InMemoryFileSystem(root: 5, files: 1))
        let page = try tree.page(of: 2, from: 0, includeDots: true, limit: 10)
        #expect(page[0].mountID == 2 && page[0].kind == .directory)
        #expect(page[1].mountID == 2, "the root's '..' is the root itself")
        #expect(page[2].mountID == 1000)
    }

    @Test func withoutDotsCookiesStillSkipTheirSlots() throws {
        let tree = try MountedTree(InMemoryFileSystem(root: 5, files: 4))
        let first = try tree.page(of: 2, from: 0, includeDots: false, limit: 2)
        #expect(first.map(\.displayName) == ["f0", "f1"])
        let rest = try tree.page(of: 2, from: try #require(first.last).nextCookie, includeDots: false, limit: 10)
        #expect(rest.map(\.displayName) == ["f2", "f3"])
    }

    @Test func cookieOneIsInvalid() throws {
        let tree = try MountedTree(InMemoryFileSystem(root: 5, files: 4))
        #expect(throws: DiskError.self) { try tree.page(of: 2, from: 1, includeDots: false, limit: 2) }
    }
}
