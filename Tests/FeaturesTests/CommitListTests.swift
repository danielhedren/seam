import Foundation
import SeamCore
import TestSupport
import Testing

@testable import Features

/// What the commit list says while it has no commits to show (SPEC §7.2.1).
@MainActor
struct CommitListTests {
    @Test func aLoadedWorktreeListsItsCommits() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.commitLog?.commits.map(\.subject) == ["Add a"])
        #expect(CommitList.status(of: review) == nil)
    }

    @Test func aSlowLoadShowsProgressOnlyAfter150Milliseconds() async throws {
        let repo = try await FixtureRepo()
        let git = GatedGit(repo.git, holding: repo.main)
        let clock = ManualClock()
        let session = RepoSession(directory: repo.main, services: services(git, clock: clock))
        await session.open()
        let review = try #require(session.selected)

        await clock.sleepers()
        #expect(CommitList.status(of: review) == nil)
        clock.advance(by: .milliseconds(150))
        while !review.showsProgress { await Task.yield() }
        #expect(CommitList.status(of: review) == .loading)
        git.release()
        await review.loaded()
    }

    @Test func aMissingDirectorySaysSo() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("gone", branch: "gone", from: "origin/main")
        try FileManager.default.removeItem(at: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.commitLog == nil)
        #expect(CommitList.status(of: review) == .missingDirectory)
    }

    @Test func aBaseThatNoLongerExistsIsNamed() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        session.setBaseOverride("refs/heads/deleted")
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.commitLog == nil)
        #expect(CommitList.status(of: review) == .baseGone("deleted"))
    }

    @Test func commitsFromABaseThatWentAwayAreNotListed() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        session.setBaseOverride("refs/heads/deleted")
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.commitLog != nil)
        #expect(CommitList.status(of: review)?.keepsLog == false)
    }
}
