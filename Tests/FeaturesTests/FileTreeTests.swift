import Foundation
import Testing

@testable import Features

@Suite struct FileTreeTests {
    private let paths = [
        "src/Orders.Service/Delivery/A.cs", "src/Orders.Service/Delivery/B.cs",
        "src/Orders.Service/C.cs",
        "README.md",
    ]

    @Test func singleChildDirectoriesAreCompacted() {
        let rows = FileTree.rows(paths)
        #expect(
            rows.map(\.name) == [
                "src/Orders.Service", "Delivery", "A.cs", "B.cs", "C.cs", "README.md",
            ])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 1, 0])
        #expect(rows[2].id == "src/Orders.Service/Delivery/A.cs")
        #expect(rows[2].kind == .file(0))
    }

    @Test func collapsedDirectoriesHideTheirContents() {
        let rows = FileTree.rows(paths, collapsed: ["src/Orders.Service/Delivery/"])
        #expect(rows.map(\.name) == ["src/Orders.Service", "Delivery", "C.cs", "README.md"])
        #expect(rows[1].kind == .directory(isExpanded: false))
    }

    @Test func filterMatchesPathsAndIgnoresCollapsing() {
        let rows = FileTree.rows(paths, collapsed: ["src/Orders.Service/"], filter: "delivery/b")
        #expect(rows.map(\.name) == ["src/Orders.Service/Delivery", "B.cs"])
    }

    @Test func aCaretTermLeavesMatchingPathsOutAndKeepsTheTreeAsItWas() {
        let rows = FileTree.rows(
            paths, collapsed: ["src/Orders.Service/Delivery/"], filter: "^c.cs")
        // One child left, so the chain compacts; it stays collapsed as the reader left it.
        #expect(rows.map(\.name) == ["src/Orders.Service/Delivery", "README.md"])
        #expect(rows.first?.kind == .directory(isExpanded: false))
        #expect(
            FileTree.rows(paths, filter: "orders ^delivery").map(\.name) == [
                "src/Orders.Service", "C.cs",
            ])
    }

    @Test(arguments: [
        ("", "src/Tests/A.cs", true), ("tests", "src/Tests/A.cs", true),
        ("^test", "src/Tests/A.cs", false), ("^test", "src/A.cs", true),
        ("src ^test", "src/A.cs", true), ("src ^test", "lib/A.cs", false), ("^", "src/A.cs", true),
    ])
    func filterTermsAllMatchAndCaretTermsNone(filter: String, path: String, kept: Bool) {
        #expect(FileFilter(filter).matches(path) == kept)
    }

    @Test func generatedFilesSitUnderTheirOwnClosedHeading() {
        let paths = ["src/a.cs", "src/Generated/b.cs", "package-lock.json"]
        let closed = FileTree.rows(paths, generated: [1, 2])
        #expect(closed.map(\.name) == ["src", "a.cs", "Generated"])
        #expect(closed.last?.kind == .generated(count: 2, isExpanded: false))
        let open = FileTree.rows(paths, generated: [1, 2], showsGenerated: true)
        #expect(open.suffix(2).map(\.name) == ["src/Generated/b.cs", "package-lock.json"])
    }

    @Test func aPathListedTwiceGetsDistinctRowIDs() {
        let rows = FileTree.rows(["link", "link"], flat: true)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.map(\.name) == ["link", "link"])
        #expect(Set(FileTree.rows(["a/link", "a/link"]).map(\.id)).count == 3)
    }

    @Test func flatListShowsFullPathsInReviewOrder() {
        #expect(FileTree.rows(paths, flat: true).map(\.name) == paths)
    }
}

@Suite struct FuzzyMatchTests {
    @Test func subsequencesMatchAndBetterMatchesScoreHigher() throws {
        let exact = try #require(FuzzyMatch.score("1894", in: "ticket-1894-remove-preview"))
        let scattered = try #require(FuzzyMatch.score("1894", in: "ticket-1872-preview-9-4"))
        #expect(exact > scattered)
        #expect(FuzzyMatch.score("xyz", in: "ticket-1894") == nil)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }
}
