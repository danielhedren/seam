import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import Synchronization
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

    private func open(_ repo: FixtureRepo, held: HeldStore? = nil) async -> RepoSession {
        var services = services(repo.git, store: store, github: GitHubAccount(client: github))
        let origin = repo.origin.path
        let storeDirectory = repo.directory.resolved.appending(path: "state/pulls.git")
        services.pullRequestStore = { repository in
            let store = CLIPullRequestStore(
                directory: storeDirectory,
                objects: repository.commonDirectory.appending(path: "objects"),
                remoteURL: { _ in origin })
            held?.inner.withLock { $0 = store }
            return held ?? store
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

    @Test func aPushAfterAFileWasViewedShowsAsNewCommitsAndAsAChangedFile() async throws {
        let (repo, pullRequest) = try await fixture()
        let session = await open(repo)
        session.noteActivation(false)
        let review = try await openReview(session, 8)
        session.toggleViewed("b.txt", advance: false)
        #expect(session.pullRequestsWithNewCommits.isEmpty)

        try await repo.run("switch", "-q", "-c", "pushed", "main")
        let pushed = try await repo.commit("b.txt", "b, again\n", "Rework b")
        try await repo.run("push", "-q", "-f", repo.origin.path, "pushed:refs/pull/8/head")
        var moved = pullRequest
        moved.headCommit = pushed
        moved.updated = pullRequest.updated.addingTimeInterval(60)
        github.answer(open: [moved])
        session.reload()
        await session.settled()
        await until { review.pullRequest?.headCommit == pushed }
        await review.loaded()

        #expect(session.pullRequestsWithNewCommits == [8])
        #expect(review.viewedStatus("b.txt") == .changedSinceViewed)
        let platform = try #require(session.services.platform as? RecordingPlatform)
        #expect(
            platform.notified.map(\.body).contains("New commits since you last viewed it"),
            "\(platform.notified.map(\.body))")
        session.close()
    }

    @Test func aCommentOnAPullRequestOpenedInSeamIsNewsTitledWithIt() async throws {
        let (repo, _) = try await fixture()
        let session = await open(repo)
        session.noteActivation(false)
        let review = try await openReview(session, 8)
        await until { session.pullRequestThreads?.readThisSession(review.id) == 8 }
        let platform = try #require(session.services.platform as? RecordingPlatform)

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
        session.pullRequestThreads?.forgetReads()
        session.reload()
        await until { !platform.notified.isEmpty }

        #expect(platform.notified.map(\.title) == ["#8 Count the lines"])
        #expect(platform.notified.map(\.body) == ["octocat on #8: Why b?"])
        #expect(platform.notified.first?.url == SeamURL(path: repo.main.path, pullRequest: 8).url)
        session.close()
    }

    @Test func aPullRequestNotFetchedYetSaysItsBeingFetched() async throws {
        let (repo, _) = try await fixture()
        let held = HeldStore()
        let session = await open(repo, held: held)

        session.openPullRequestReview(8)
        let review = try #require(session.selected)
        await until { review.isFetching }
        #expect(review.diff == nil)
        held.release()
        await review.loaded()

        #expect(!review.isFetching)
        #expect(review.diff?.files.map(\.diff.path) == ["b.txt"])
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

/// The real store, its fetches held until released.
final class HeldStore: PullRequestStore {
    let inner = Mutex<CLIPullRequestStore?>(nil)
    private let gate = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    var directory: URL { inner.withLock { $0?.directory } ?? URL(fileURLWithPath: "/") }

    func release() {
        let waiting = gate.withLock { gate in
            gate.open = true
            defer { gate.waiting = [] }
            return gate.waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    func fetch(pullRequests: [Int], bases: [String], from repo: GitHubRepo) async throws(GitError) {
        await withCheckedContinuation { continuation in
            let open = gate.withLock { gate in
                if !gate.open { gate.waiting.append(continuation) }
                return gate.open
            }
            if open { continuation.resume() }
        }
        try await inner.withLock { $0 }?.fetch(pullRequests: pullRequests, bases: bases, from: repo)
    }

    func reset() async {
        await inner.withLock { $0 }?.reset()
    }
}
