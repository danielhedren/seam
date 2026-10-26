import AppKit
import DiffModel
import DiffView
import Foundation
import ReviewTestSupport
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct SearchTests {
    private func session(_ repo: FixtureRepo, clock: ManualClock = ManualClock()) async throws
        -> (RepoSession, WorktreeReview)
    {
        let session = RepoSession(directory: repo.main, services: services(repo.git, clock: clock))
        await session.open()
        await session.settled()
        return (session, try #require(session.selected))
    }

    /// Types a query and lets the pause pass.
    private func search(_ text: String, in review: WorktreeReview, clock: ManualClock) async {
        review.navigator = .search
        review.search = TextQuery(text)
        await clock.sleepers()
        clock.advance(by: WorktreeReview.filterDelay)
        await until { review.appliedSearch.text == text }
    }

    @Test func searchNarrowsTheDiffToFilesWithMatchesOnceTypingPausesAndHighlightsThem()
        async throws
    {
        let repo = try await FixtureRepo()
        try repo.write("src/delivery.txt", "x\n")
        try repo.write("a.txt", "one\nDelivery two\n")
        try repo.write("b.txt", "nothing\n")
        let clock = ManualClock()
        let (session, review) = try await session(repo, clock: clock)
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
        #expect(SearchSummary.text(try #require(review.searchResult)) == "2 matches in 2 files")

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
        let (_, review) = try await session(repo, clock: clock)
        await search("hit", in: review, clock: clock)

        let folds = review.searchRows.map { row -> Bool? in
            if case .file(let file) = row.kind { file.isFolded } else { nil }
        }
        #expect(folds == [true, false, nil] as [Bool?])
        review.toggleFold("many.txt")
        #expect(review.searchRows.count == 28, "two files, 25 lines and 1")
        let line = try #require(review.searchResult?.files[1].lines.first)
        #expect(line.kind == .added && line.number == 1 && line.text == "a hit")
    }

    @Test func pickingALineOpensItsCollapsedFileAndMakesItsMatchCurrent() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "hit\nmiss\nhit hit\n")
        let clock = ManualClock()
        let (session, review) = try await session(repo, clock: clock)
        await search("hit", in: review, clock: clock)
        let view = try showDiff(session)
        var results: [String] = []
        view.onSearchResult = { current, total in results.append("\(current ?? 0)/\(total)") }
        session.refreshDiffQuery()
        #expect(results.last == "1/3")

        session.toggleCollapsed("a.txt")
        view.show(try #require(review.content), position: .keep)
        let row = try #require(
            review.searchRows.first {
                if case .line(_, let line) = $0.kind { line.number == 3 } else { false }
            })
        review.pick(row, controller: session.diff)
        #expect(!review.collapsed.contains("a.txt"))
        view.show(try #require(review.content), position: .keep)

        #expect(results.last == "2/3", "the first match on line 3")
        #expect(review.selectedSearchRow == row.id)
    }

    @Test func rowsFromAnEarlierResultStillDrawAndPickAfterTheResultShrinks() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "hit\n")
        try repo.write("b.txt", "hit\nhit again\n")
        let clock = ManualClock()
        let (session, review) = try await session(repo, clock: clock)
        await search("hit", in: review, clock: clock)
        let stale = review.searchRows
        #expect(stale.count == 5)

        await search("again", in: review, clock: clock)
        let host = NSHostingView(
            rootView: VStack { ForEach(stale) { SearchRowView(row: $0, review: review) } })
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()
        for row in stale { review.pick(row, controller: session.diff) }
        #expect(review.selectedSearchRow == stale.last?.id)
    }

    @Test func searchInReviewShowsSearchAndFilterFilesGoesBack() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "x\n")
        let (session, review) = try await session(repo)
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
