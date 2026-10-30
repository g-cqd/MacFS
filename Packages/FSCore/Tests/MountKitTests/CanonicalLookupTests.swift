import FSCore
import Testing

/// Names as macOS asks for them (roadmap 0022): Cocoa and Finder pass decomposed (NFD) names, Linux and Windows store
/// precomposed (NFC) ones. An exact match wins; failing that, a canonically equivalent name is the same name, as APFS treats it.
@Suite struct CanonicalLookupTests {
    static let composed = "na\u{EF}ve.txt"  // NFC: ï as one scalar
    static let decomposed = "nai\u{308}ve.txt"  // NFD: i and a combining diaeresis

    static func fileSystem(_ names: [String]) -> InMemoryFileSystem {
        var fileSystem = InMemoryFileSystem(root: 5, files: 0)
        for (index, name) in names.enumerated() {
            let id = UInt64(2000 + index)
            fileSystem.nodes[5]?.children.append((name, id))
            fileSystem.nodes[id] = InMemoryFileSystem.Node(
                attributes: NodeAttributes(id: id, parent: 5, kind: .regular))
        }
        return fileSystem
    }

    @Test func aDecomposedNameFindsTheComposedOne() throws {
        let fileSystem = Self.fileSystem([Self.composed])
        #expect(throws: DiskError.self) { try fileSystem.lookup(Array(Self.decomposed.utf8), in: 5) }
        let entry = try fileSystem.lookupCanonical(Array(Self.decomposed.utf8), in: 5)
        #expect(entry.id == 2000)
        #expect(entry.name == Array(Self.composed.utf8), "the name as stored")
    }

    @Test func anExactMatchWinsWhenBothFormsExist() throws {
        let fileSystem = Self.fileSystem([Self.composed, Self.decomposed])
        #expect(try fileSystem.lookupCanonical(Array(Self.decomposed.utf8), in: 5).id == 2001)
        #expect(try fileSystem.lookupCanonical(Array(Self.composed.utf8), in: 5).id == 2000)
    }

    @Test func otherNamesStillMiss() {
        let fileSystem = Self.fileSystem([Self.composed])
        #expect(throws: DiskError.notFound) { try fileSystem.lookupCanonical(Array("naive.txt".utf8), in: 5) }
        #expect(throws: DiskError.notFound) { try fileSystem.lookupCanonical([0x6E, 0xFF, 0x61], in: 5) }
    }
}
