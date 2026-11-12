import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// Reviewing a listed pull request from Seam's store (SPEC §6.4, §7.2.2, §8.3.1).
@MainActor @Suite(.timeLimit(.minutes(1))) struct PullRequestReviewTests {
    let github = FakeGitHub()
    let store = MemoryStore()

    /// Pull request #8 adds `b.txt` on main; only origin has its commit.
    private func fixture() async throws -> (FixtureRepo, PullRequest) {
        let repo = try await FixtureRepo()
        let head = try await repo.openPullRequest(8, file: "b.txt", "b\n")
        let base = try await repo.sha("origin/main")
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        var pullRequest = fakePullRequest(8, head: "pr-8-source", headCommit: head)
        pullRequest.baseCommit = base
        pullRequest.author = "anna"
        github.answer(open: [pullRequest])
        return (repo, pullRequest)
    }

    private func open(_ repo: FixtureRepo) async -> RepoSession {
        var services = services(repo.git, store: store, github: GitHubAccount(client: github))
        let origin = repo.origin.path
        let storeDirectory = repo.directory.resolved.appending(path: "state/pulls.git")
        services.pullRequestStore = { repository in
            CLIPullRequestStore(
                directory: storeDirectory,
                objects: repository.commonDirectory.appending(path: "objects"),
                remoteURL: { _ in origin })
        }
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        await session.pullRequests?.idle()
        return session
    }

    private func openReview(_ session: RepoSession, _ number: Int) async throws -> WorktreeReview {
        session.openPullRequestReview(number)
        let review = try #require(session.selected)
        await review.loaded()
        return review
    }

    @Test func pickingAListedPullRequestReviewsItsChangeFromTheStore() async throws {
        let (repo, pullRequest) = try await fixture()
        let refsBefore = try await repo.run("for-each-ref")
        let session = await open(repo)

        let review = try await openReview(session, 8)

        #expect(review.id == "pr:8")
        #expect(review.isPullRequestReview)
        #expect(review.problem == nil)
        #expect(review.diff?.files.map(\.diff.path) == ["b.txt"])
        #expect(review.commitLog?.commits.map(\.id) == [pullRequest.headCommit])
        #expect(review.parentName == "main")
        #expect(try await repo.run("for-each-ref") == refsBefore)
        #expect(
            !FileManager.default.fileExists(
                atPath: repo.main.appending(path: ".git/FETCH_HEAD").path))
        session.close()
    }

    @Test func gitHubsThreadsOnThePullRequestShowOnItsReview() async throws {
        let (repo, _) = try await fixture()
        github.answer(
            threads: [
                GitHubReviewThread(
                    id: "PRRT_1", path: "b.txt", isResolved: false, side: .right, lines: 1...1,
                    comments: [
                        .init(
                            id: 7, author: "octocat", body: "Why b?", created: .distantPast,
                            url: "https://github.com/owner/app/pull/8#discussion_r7",
                            diffHunk: "@@ -0,0 +1 @@\n+b")
                    ])
            ], for: 8)
        let session = await open(repo)

        let review = try await openReview(session, 8)
        await until { !review.placedThreads.isEmpty }

        #expect(review.placedThreads.map(\.id) == ["gh-7"])
        #expect(review.placedThreads.first?.placement == .lines(1...1))
        #expect(github.threadReads == [8])
        session.close()
    }

    /// Fetched in the background after the list is read, before anything is opened.
    @Test func aListedPullRequestsTotalsAreCountedInTheStore() async throws {
        let (repo, _) = try await fixture()
        let session = await open(repo)

        await until { session.pullRequestTotals[8] != nil }

        #expect(session.pullRequestTotals == [8: DiffStat(files: 1, additions: 1, deletions: 0)])
        #expect(session.pullRequestReviews.isEmpty)
        session.close()
    }

    @Test func aPullRequestReviewOffersNothingThatNeedsACheckout() async throws {
        let (repo, _) = try await fixture()
        let session = await open(repo)
        _ = try await openReview(session, 8)

        for id in ["comment", "editor", "base", "worktree-editor", "agent-prompt"] {
            let command = try #require(CommandCatalog.byID[id])
            #expect(!command.isEnabled(session), "\(id)")
        }
        #expect(CommandCatalog.byID["pull-request-open"]?.isEnabled(session) == true)
        session.close()
    }

    @Test func viewedFilesOfAPullRequestAreKeptAcrossLaunches() async throws {
        let (repo, _) = try await fixture()
        let first = await open(repo)
        _ = try await openReview(first, 8)
        first.toggleViewed("b.txt", advance: false)
        await first.settled()
        first.close()

        let session = await open(repo)
        let review = try await openReview(session, 8)

        #expect(review.viewedStatus("b.txt") == .viewed)
        session.close()
    }
}
