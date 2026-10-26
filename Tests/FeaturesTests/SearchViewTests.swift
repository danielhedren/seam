import AppKit
import DiffModel
import Foundation
import ReviewTestSupport
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct SearchViewTests {
    @Test func pickingALineOpensItsCollapsedFileAndMakesItsMatchCurrent() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "hit\nmiss\nhit hit\n")
        let clock = ManualClock()
        let (session, review) = try await openedSession(repo, clock: clock)
        await review.searchSettled("hit", clock: clock)
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
        let (session, review) = try await openedSession(repo, clock: clock)
        await review.searchSettled("hit", clock: clock)
        let stale = review.searchRows
        #expect(stale.count == 5)

        await review.searchSettled("again", clock: clock)
        let host = NSHostingView(
            rootView: VStack { ForEach(stale) { SearchRowView(row: $0, review: review) } })
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        host.layoutSubtreeIfNeeded()
        for row in stale { review.pick(row, controller: session.diff) }
        #expect(review.selectedSearchRow == stale.last?.id)
    }
}
