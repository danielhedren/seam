import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// Other people's open pull requests under the worktrees (SPEC §7.2.2).
@MainActor @Suite(.timeLimit(.minutes(1))) struct PullRequestListTests {
    let github = FakeGitHub()
    let clock = ManualClock()
    let store = MemoryStore()
    let platform = RecordingPlatform()

    /// The main worktree and a `feature` worktree, whose PR is #12; origin on GitHub.
    private func fixture() async throws -> FixtureRepo {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        return repo
    }

    private func open(_ repo: FixtureRepo, settings: AppSettings? = nil) async -> RepoSession {
        var services = services(
            repo.git, clock: clock, store: store, github: GitHubAccount(client: github))
        services.platform = platform
        if let settings { services.settings = settings }
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        return session
    }

    private func others(_ numbers: [Int], by author: String = "anna") -> [PullRequest] {
        numbers.map { number in
            var pullRequest = fakePullRequest(number, head: "other-\(number)")
            pullRequest.author = author
            pullRequest.updated = Date(timeIntervalSince1970: Double(number))
            return pullRequest
        }
    }

    private func reload(_ session: RepoSession) async {
        session.reload()
        await session.settled()
        await session.pullRequests?.idle()
    }

    @Test func othersPullRequestsAreListedButNotTheReadersNorAWorktrees() async throws {
        let repo = try await fixture()
        var mine = fakePullRequest(30, head: "mine")
        mine.author = "me"
        github.answer(open: [fakePullRequest(12)] + others([20, 21]) + [mine])
        github.answer(reviewRequests: [20])

        let session = await open(repo)

        #expect(session.showsPullRequestList)
        let listing = session.pullRequestListing
        #expect(listing.rows.map(\.id) == [20, 21])
        #expect(listing.rows.map(\.isReviewRequested) == [true, false])
        #expect(github.requestReads == 1)
        session.close()
    }

    @Test func filtersAreKeptForTheRepoAcrossLaunches() async throws {
        let repo = try await fixture()
        github.answer(open: others([20]) + others([21], by: "bob"))
        let first = await open(repo)
        first.pullRequestFilter.hidesDrafts = true
        first.hidePullRequests(by: "bob")
        #expect(first.pullRequestListing.rows.map(\.id) == [20])
        await first.settled()
        first.close()

        let session = await open(repo)

        #expect(
            session.pullRequestFilter
                == PullRequestFilter(hidesDrafts: true, authors: .init(.hide, ["bob"])))
        #expect(session.pullRequestListing.rows.map(\.id) == [20])
        #expect(session.pullRequestListing.hidden == 1)
        session.close()
    }

    @Test func aPullRequestHiddenByHandIsForgottenOnceItCloses() async throws {
        let repo = try await fixture()
        github.answer(open: others([20, 21]))
        let session = await open(repo)
        session.hidePullRequest(20)
        #expect(session.pullRequestListing.rows.map(\.id) == [21])

        github.answer(open: others([21]))
        await reload(session)

        #expect(session.pullRequestFilter.hiddenNumbers.isEmpty)
        session.close()
    }

    @Test func turnedOffTheListIsntReadOrShown() async throws {
        let repo = try await fixture()
        github.answer(open: others([20]))
        let settings = testSettings()
        settings.showsPullRequestList = false

        let session = await open(repo, settings: settings)

        #expect(!session.showsPullRequestList)
        #expect(github.requestReads == 0)
        #expect(session.pullRequests?.saved.open == nil)
        session.close()
    }

    @Test func aRowCopiesTheCommandsThatCheckItOut() async throws {
        let repo = try await fixture()
        github.answer(open: others([20]))
        let session = await open(repo)

        session.copyWorktreeCommand(for: 20)
        session.copyListedPullRequestURL(20)
        session.openListedPullRequest(20)

        #expect(
            platform.copied == [
                "git fetch origin pull/20/head:pr-20 && git worktree add ../pr-20 pr-20",
                "https://github.com/owner/app/pull/20",
            ])
        #expect(platform.opened == [URL(string: "https://github.com/owner/app/pull/20")])
        session.close()
    }

    @Test func aReviewAskedOfTheReaderAndANewPullRequestEachNotifyOnce() async throws {
        let repo = try await fixture()
        github.answer(open: others([20]))
        let session = await open(repo)
        session.noteActivation(false)

        github.answer(open: others([20, 21, 22]))
        github.answer(reviewRequests: [20])
        session.pullRequestFilter.hiddenNumbers = [22]
        await reload(session)
        await until { platform.notified.count == 2 }
        await reload(session)

        #expect(
            platform.notified.map(\.title) == ["#20 Count the lines", "#21 Count the lines"])
        #expect(
            platform.notified.map(\.body) == [
                "anna asks you to review", "New pull request by anna",
            ])
        #expect(platform.notified.first?.url == SeamURL(path: repo.main.path, pullRequest: 20).url)
        session.close()
    }

    @Test func notificationKindsAddedLaterStartOnForAReaderWhoChoseSomeBefore() {
        let defaults = Scratch.defaults("seam-tests")
        defaults.set(
            ["agent", "checks", "review", "comment", "closed"], forKey: "seam.notifications")

        let settings = AppSettings(defaults: defaults)

        #expect(
            settings.notifications
                == [.agent, .checks, .review, .comment, .closed, .reviewRequested, .newPullRequest])
        settings.notifications.remove(.newPullRequest)
        #expect(
            AppSettings(defaults: defaults).notifications
                == [.agent, .checks, .review, .comment, .closed, .reviewRequested])
    }
}
