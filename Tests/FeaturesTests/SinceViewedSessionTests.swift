import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import DiffModel
@testable import DiffView
@testable import Features
@testable import ReviewModel

/// Review › Show Changes Since Viewed (SPEC §7.4), through the catalog command and the session.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SinceViewedSessionTests {
    private func numbered(_ range: ClosedRange<Int>, replacing: [Int: String] = [:]) -> String {
        range.map { replacing[$0] ?? "\($0)" }.joined(separator: "\n") + "\n"
    }

    private func changes(_ review: WorktreeReview) -> [String]? {
        review.content?.review.files.first { $0.diff.path == "a.txt" }?.diff.hunks
            .flatMap(\.lines).filter { $0.kind != .context }.map(\.text)
    }

    /// Marks a.txt viewed, then changes line 10 the way an agent would.
    private func viewedThenChanged(_ repo: FixtureRepo, store: MemoryStore) async throws
        -> (RepoSession, WorktreeReview)
    {
        let session = RepoSession(
            directory: repo.main, services: services(repo.git, store: store))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        review.currentFile = "a.txt"
        session.toggleViewed("a.txt", advance: false)
        await session.settled()
        try repo.write("a.txt", numbered(1...20, replacing: [10: "ten"]))
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()
        return (session, review)
    }

    @Test func aFileChangedSinceViewedShowsOnlyWhatChangedAndGoesBack() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numbered(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        let show = try command("since-viewed")
        #expect(show.isEnabled(session))
        #expect(changes(review)?.count == 20)

        show.run(session)
        await until { review.sinceViewed["a.txt"] != nil }
        #expect(changes(review) == ["10", "ten"])
        #expect(review.content?.sinceViewed == ["a.txt"])
        #expect(review.content?.contents["a.txt"]?.old == numbered(1...20))
        #expect(show.title(for: session) == "Show Full Diff")
        // The earlier copy's lines aren't the base's, so they can't be commented on.
        #expect(review.anchor(path: "a.txt", side: .old, lines: 10...10) == nil)
        #expect(review.anchor(path: "a.txt", side: .new, lines: 10...10)?.text == ["ten"])

        show.run(session)
        await until { review.sinceViewed.isEmpty }
        #expect(changes(review)?.count == 20)
        #expect(review.content?.sinceViewed == [])
    }

    /// The diff itself redraws with the change since viewed, not only the review's content.
    @Test func theDiffOnScreenShowsTheChangeSinceViewed() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numbered(1...20))
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

    @Test func markingItViewedAgainShowsTheFullDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numbered(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        await session.toggleSinceViewed("a.txt")
        #expect(changes(review) == ["10", "ten"])

        session.toggleViewed("a.txt", advance: false)
        #expect(review.sinceViewed.isEmpty)
        #expect(changes(review)?.count == 20)
        #expect(try !command("since-viewed").isEnabled(session))
    }

    @Test func theFilesMenuShowsTheChangeAndTheFullDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numbered(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        func item(_ title: String) -> FileActions.Action? {
            FileActions.actions(for: "a.txt", in: session).flatMap(\.self).first {
                $0.title == title
            }
        }
        #expect(item("Show Full Diff") == nil)

        try #require(item("Show Changes Since Viewed")).run()
        await until { review.sinceViewed["a.txt"] != nil }
        #expect(changes(review) == ["10", "ten"])
        #expect(item("Show Changes Since Viewed") == nil)

        try #require(item("Show Full Diff")).run()
        await until { review.sinceViewed.isEmpty }
        #expect(changes(review)?.count == 20)
    }

    /// Seam lost its copy, but the version was staged, so git still has it.
    @Test func aVersionSeamDidntKeepComesFromGitWhenItHasIt() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numbered(1...20))
        try await repo.run("add", "a.txt")
        let store = MemoryStore()
        let (session, review) = try await viewedThenChanged(repo, store: store)
        await store.forgetSeen()

        await session.toggleSinceViewed("a.txt")
        #expect(changes(review) == ["10", "ten"])
    }

    @Test func aVersionNobodyHasSaysSoAndKeepsTheFullDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numbered(1...20))
        let store = MemoryStore()
        let (session, review) = try await viewedThenChanged(repo, store: store)
        await store.forgetSeen()

        await session.toggleSinceViewed("a.txt")
        #expect(review.problem == .seenGone("a.txt"))
        #expect(review.sinceViewed.isEmpty)
        #expect(changes(review)?.count == 20)
    }
}
