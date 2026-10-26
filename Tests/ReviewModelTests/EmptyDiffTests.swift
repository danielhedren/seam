import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EmptyDiffTests {
    @Test func aFilterThatLeavesNoFileSaysSoAndOffersToClearIt() async throws {
        let repo = try await FixtureRepo()
        try repo.write("src/a.cs", "x\n")
        let clock = ManualClock()
        let session = RepoSession(directory: repo.main, services: services(repo.git, clock: clock))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        #expect(EmptyDiff.of(review) == nil)

        review.fileFilter = "nothing"
        await clock.sleepers()
        clock.advance(by: WorktreeReview.filterDelay)
        await until { EmptyDiff.of(review) != nil }
        #expect(EmptyDiff.of(review)?.action == .clearFilter)
        #expect(EmptyDiff.of(review)?.detail.contains("“nothing”") == true)
    }

    @Test func anEmptyScopeOffersAllChangesWhenTheWorktreeHasSome() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try repo.write("notes.md", "# Notes\n", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)
        #expect(EmptyDiff.of(review) == nil)

        session.setScope(.committed)
        await session.settled()
        let empty = try #require(EmptyDiff.of(review))
        #expect(empty.title == "No commits since origin/main")
        #expect(empty.action == .showAll)
    }

    @Test func aCleanWorktreeExplainsItselfWithoutAnAction() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)

        let empty = try #require(EmptyDiff.of(review))
        #expect(empty.title == "No changes against origin/main")
        #expect(empty.action == nil)
    }
}
