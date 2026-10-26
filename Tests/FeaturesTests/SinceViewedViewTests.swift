import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import DiffView
@testable import Features
@testable import ReviewModel

/// Show Changes Since Viewed (SPEC §7.4) in the drawn diff and the file menu.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SinceViewedViewTests {
    /// The diff itself redraws with the change since viewed, not only the review's content.
    @Test func theDiffOnScreenShowsTheChangeSinceViewed() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        let pane = CardWindow(session: session, review: review)
        func drawn() -> [String]? {
            CardWindow.find(DiffCanvasView.self, in: pane.window.contentView)?.review.files
                .first?.diff.hunks.flatMap(\.lines).filter { $0.kind != .context }.map(\.text)
        }
        #expect(await pane.wait { drawn()?.count == 20 })

        await session.toggleSinceViewed("a.txt")
        #expect(await pane.wait { drawn() == ["10", "ten"] })
        await session.toggleSinceViewed("a.txt")
        #expect(await pane.wait { drawn()?.count == 20 })
    }

    @Test func theFilesMenuShowsTheChangeAndTheFullDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        func item(_ title: String) -> FileActions.Action? {
            FileActions.actions(for: "a.txt", in: session).flatMap(\.self).first {
                $0.title == title
            }
        }
        #expect(item("Show Full Diff") == nil)

        try #require(item("Show Changes Since Viewed")).run()
        await until { review.sinceViewed["a.txt"] != nil }
        #expect(changedLines(review) == ["10", "ten"])
        #expect(item("Show Changes Since Viewed") == nil)

        try #require(item("Show Full Diff")).run()
        await until { review.sinceViewed.isEmpty }
        #expect(changedLines(review)?.count == 20)
    }
}
