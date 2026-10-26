import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import DiffModel
@testable import ReviewModel

/// Review › Show Changes Since Viewed (SPEC §7.4), through the catalog command and the session.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SinceViewedSessionTests {
    @Test func aFileChangedSinceViewedShowsOnlyWhatChangedAndGoesBack() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        let show = try command("since-viewed")
        #expect(show.isEnabled(session))
        #expect(changedLines(review)?.count == 20)

        show.run(session)
        await until { review.sinceViewed["a.txt"] != nil }
        #expect(changedLines(review) == ["10", "ten"])
        #expect(review.content?.sinceViewed == ["a.txt"])
        #expect(review.content?.contents["a.txt"]?.old == numberedLines(1...20))
        #expect(show.title(for: session) == "Show Full Diff")
        // The earlier copy's lines aren't the base's, so they can't be commented on.
        #expect(review.anchor(path: "a.txt", side: .old, lines: 10...10) == nil)
        #expect(review.anchor(path: "a.txt", side: .new, lines: 10...10)?.text == ["ten"])

        show.run(session)
        await until { review.sinceViewed.isEmpty }
        #expect(changedLines(review)?.count == 20)
        #expect(review.content?.sinceViewed == [])
    }

    @Test func markingItViewedAgainShowsTheFullDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...20))
        let (session, review) = try await viewedThenChanged(repo, store: MemoryStore())
        await session.toggleSinceViewed("a.txt")
        #expect(changedLines(review) == ["10", "ten"])

        session.toggleViewed("a.txt", advance: false)
        #expect(review.sinceViewed.isEmpty)
        #expect(changedLines(review)?.count == 20)
        #expect(try !command("since-viewed").isEnabled(session))
    }

    /// Seam lost its copy, but the version was staged, so git still has it.
    @Test func aVersionSeamDidntKeepComesFromGitWhenItHasIt() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...20))
        try await repo.run("add", "a.txt")
        let store = MemoryStore()
        let (session, review) = try await viewedThenChanged(repo, store: store)
        await store.forgetSeen()

        await session.toggleSinceViewed("a.txt")
        #expect(changedLines(review) == ["10", "ten"])
    }

    @Test func aVersionNobodyHasSaysSoAndKeepsTheFullDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", numberedLines(1...20))
        let store = MemoryStore()
        let (session, review) = try await viewedThenChanged(repo, store: store)
        await store.forgetSeen()

        await session.toggleSinceViewed("a.txt")
        #expect(review.problem == .seenGone("a.txt"))
        #expect(review.sinceViewed.isEmpty)
        #expect(changedLines(review)?.count == 20)
    }
}
