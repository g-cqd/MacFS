import Foundation
import Testing
import ToolingCore

// The rules on synthetic trees first (each must be seen to fire), then on this repository.
@Suite struct RepositoryRulesTests {
    static let goodDocs: [String: String] = [
        "docs/WHITE-PAPER.md": "# White paper\n",
        "docs/adr/0001-one.md": "---\nstatus: accepted\ndate: 2026-10-30\n---\n\n# 0001 — One\n",
        "docs/adr/0002-two.md":
            "---\nstatus: superseded\nsuperseded-by: [\"0003\"]\ndate: 2026-10-30\n---\n\n# 0002 — Two\n",
        "docs/adr/0003-three.md":
            "---\nstatus: accepted\nsupersedes: [\"0002\"]\ndate: 2026-10-30\n---\n\n# 0003 — Three\n",
        "docs/roadmap/0001-a.md": "---\nstatus: done\nblocked-by: []\ndate: 2026-10-30\n---\n\n# 0001 — A\n",
        "docs/roadmap/0002-b.md": "---\nstatus: open\nblocked-by: [\"0003\"]\ndate: 2026-10-30\n---\n\n# 0002 — B\n",
        "docs/roadmap/0003-c.md": "---\nstatus: open\nblocked-by: []\ndate: 2026-10-30\n---\n\n# 0003 — C\n",
        "docs/diary/2026-10-30-01.md": "# Diary — 2026-10-30 (01)\n",
        // What each reader is held to (references, suites, performance), one page per format.
        "docs/conformance/README.md": "# Conformance\n",
        "docs/conformance/ext.md": "# ext\n"
    ]

    @Test func aWellFormedTreeHasNoProblems() {
        #expect(DocumentationLayout.problems(Self.goodDocs) == [])
    }

    @Test(arguments: [
        ("docs/WHITE-PAPER.md", String(repeating: "line\n", count: 201), "WHITE-PAPER.md has 201 lines (cap 200)"),
        (
            "docs/adr/0004-x.md", "---\nstatus: proposed\ndate: 2026-10-30\n---\n",
            "docs/adr/0004-x.md: status must be accepted or superseded"
        ),
        ("docs/adr/0005.md", "", "docs/adr/0005.md: name must be NNNN-title.md"),
        (
            "docs/roadmap/0004-d.md", "---\nstatus: open\nblocked-by: [\"0001\"]\ndate: 2026-10-30\n---\n",
            "docs/roadmap/0004-d.md: blocked by 0001, which is done"
        ),
        (
            "docs/roadmap/0005-e.md", "---\nstatus: open\nblocked-by: [\"0099\"]\ndate: 2026-10-30\n---\n",
            "docs/roadmap/0005-e.md: blocked by 0099, which does not exist"
        ),
        (
            "docs/roadmap/0006-f.md", "---\nstatus: open\ndate: 2026-10-30\n---\n",
            "docs/roadmap/0006-f.md: no blocked-by"
        ),
        (
            "docs/diary/2026-10-30-02.md", String(repeating: "x\n", count: 257),
            "docs/diary/2026-10-30-02.md has 257 lines (cap 256)"
        ),
        ("docs/notes.md", "x", "docs/notes.md: not in a documented place")
    ])
    func eachRuleFires(_ path: String, _ contents: String, _ problem: String) {
        var tree = Self.goodDocs
        tree[path] = contents
        #expect(DocumentationLayout.problems(tree).contains(problem), "\(DocumentationLayout.problems(tree))")
    }

    @Test func aSupersessionMustNameItselfBothWays() {
        var tree = Self.goodDocs
        tree["docs/adr/0003-three.md"] = "---\nstatus: accepted\ndate: 2026-10-30\n---\n"
        #expect(
            DocumentationLayout.problems(tree)
                .contains("docs/adr/0002-two.md: superseded by 0003, which does not name it"))
    }

    @Test func sourceStructureCountsTopLevelTypesAndLines() {
        let tree = [
            "Sources/A/One.swift": "struct One {\n    struct Nested {}\n}\nextension One {}\n",
            "Sources/A/Two.swift": "enum Two {}\nstruct Extra {}\n",
            "Sources/A/Long.swift": String(repeating: "// x\n", count: 251)
        ]
        #expect(
            SourceStructure.problems(tree) == [
                "Sources/A/Long.swift has 251 lines (cap 250)",
                "Sources/A/Two.swift declares 2 top-level types: Two, Extra"
            ])
    }

    // MARK: This repository

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func thisRepositorysDocumentationFollowsTheLaw() throws {
        let tree = try RepositoryFiles.read(root: Self.root.path, under: ["docs"], suffix: ".md")
        #expect(!tree.isEmpty)
        #expect(DocumentationLayout.problems(tree) == [])
    }

    @Test func thisRepositorysSourcesFollowTheStructureRule() throws {
        let tree = try RepositoryFiles.read(
            root: Self.root.path, under: ["Packages/FSCore/Sources", "Packages/Tooling/Sources", "Extensions", "App"],
            suffix: ".swift")
        #expect(tree.count > 50)
        #expect(SourceStructure.problems(tree) == [])
    }
}
