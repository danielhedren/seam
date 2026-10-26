import DiffModel
import Foundation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct SearchTests {
    @Test func searchNarrowsTheDiffToFilesWithMatchesOnceTypingPausesAndHighlightsThem()
        async throws
    {
        let repo = try await FixtureRepo()
        try repo.write("src/delivery.txt", "x\n")
        try repo.write("a.txt", "one\nDelivery two\n")
        try repo.write("b.txt", "nothing\n")
        let clock = ManualClock()
        let (session, review) = try await openedSession(repo, clock: clock)
        func shown() -> [String]? { review.content?.review.files.map(\.diff.path) }
        let all = ["src/delivery.txt", "a.txt", "b.txt"]
        #expect(shown() == all)

        session.showSearch()
        review.search.text = "delivery"
        await clock.sleepers()
        #expect(shown() == all)
        clock.advance(by: WorktreeReview.filterDelay)
        await until { shown() == ["src/delivery.txt", "a.txt"] }
        #expect(session.diffQuery == TextQuery("delivery"))
        #expect(try #require(review.searchResult).summary == "2 matches in 2 files")

        review.search.matchesCase = true
        #expect(shown() == ["src/delivery.txt"], "a toggle applies at once")
        session.find.query = "one"
        #expect(session.diffQuery == TextQuery("one"), "the find bar's query wins")
        session.find.close()

        review.navigator = .files
        #expect(shown() == all)
        #expect(session.diffQuery == TextQuery())
    }

    @Test func aFileWithManyMatchingLinesStartsFoldedAndItsChevronOpensIt() async throws {
        let repo = try await FixtureRepo()
        try repo.write("many.txt", (1...25).map { "hit \($0)\n" }.joined())
        try repo.write("one.txt", "a hit\n")
        let clock = ManualClock()
        let (_, review) = try await openedSession(repo, clock: clock)
        await review.searchSettled("hit", clock: clock)

        let folds = review.searchRows.map { row -> Bool? in
            if case .file(let file) = row.kind { file.isFolded } else { nil }
        }
        #expect(folds == [true, false, nil] as [Bool?])
        review.toggleFold("many.txt")
        #expect(review.searchRows.count == 28, "two files, 25 lines and 1")
        let line = try #require(review.searchResult?.files[1].lines.first)
        #expect(line.kind == .added && line.number == 1 && line.text == "a hit")
    }

    @Test func searchInReviewShowsSearchAndFilterFilesGoesBack() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "x\n")
        let (session, review) = try await openedSession(repo)
        let search = try #require(CommandCatalog.all.first { $0.id == "search" })
        let requests = session.searchFocusRequests

        search.run(session)
        #expect(review.navigator == .search)
        #expect(session.searchFocusRequests == requests + 1)
        #expect(search.shortcutLabel == "⇧⌘F")
        try #require(CommandCatalog.all.first { $0.id == "filter-files" }).run(session)
        #expect(review.navigator == .files)
    }

    @Test func aSnippetDropsTheIndentAndCutsSoTheFirstMatchShows() {
        let indented = SearchSnippet.make("        let delivery = 1", [12..<20])
        #expect(indented.text == "let delivery = 1")
        #expect(indented.ranges == [4..<12])

        let long = String(repeating: "x", count: 40) + "hit"
        let cut = SearchSnippet.make(long, [40..<43])
        #expect(cut.text == "…" + String(repeating: "x", count: 12) + "hit")
        #expect(cut.ranges == [13..<16])
        #expect(
            SearchSnippet.name("Delivery.cs", path: "src/Delivery.cs", [0..<3, 4..<12]) == [0..<8])
    }
}
