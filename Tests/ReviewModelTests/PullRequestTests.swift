import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import Synchronization
import TestSupport
import Testing

@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct PullRequestTests {
    let github = FakeGitHub()
    let clock = ManualClock()
    let store = MemoryStore()
    let opened = RecordingPlatform()

    /// The main worktree and a `feature` worktree with one commit, its origin on GitHub.
    private func fixture() async throws -> (FixtureRepo, URL) {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        // After the fixture's push: nothing here talks to the remote again.
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        return (repo, feature)
    }

    private func open(_ repo: FixtureRepo, selecting worktree: URL) async -> RepoSession {
        var services = services(
            repo.git, clock: clock, store: store, github: GitHubAccount(client: github))
        services.platform = opened
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        session.select(worktree.path)
        await session.settled()
        return session
    }

    private func review(_ session: RepoSession, _ worktree: URL) throws -> WorktreeReview {
        try #require(session.reviews.first { $0.id == worktree.path })
    }

    /// Waits until `sleepers` tasks wait on the clock, so moving it wakes what the test means
    /// to: after a read that worked, the spacing, the freshness timer and the poller.
    private func advance(
        _ session: RepoSession, by duration: Duration, once sleepers: Int, toRefresh count: Int
    ) async throws {
        let pullRequests = try #require(session.pullRequests)
        await clock.sleepers(sleepers)
        clock.advance(by: duration)
        await until { pullRequests.refreshes == count }
        await pullRequests.idle()
    }

    private func refreshes(_ session: RepoSession) -> Int {
        session.pullRequests?.refreshes ?? 0
    }

    @Test func aWorktreesPullRequestShowsOnItsRowOnceTheRepoOpens() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12)])

        let session = await open(repo, selecting: feature)

        let row = try review(session, feature)
        #expect(row.pullRequest?.number == 12)
        #expect(row.pullRequest?.marker == .waitingForReview)
        #expect(try review(session, repo.main).pullRequest == nil)
        #expect(session.pullRequests?.status == .ready)
        #expect(session.services.github.status == .ready)
        // The main worktree's branch is the default branch, so it isn't looked up.
        #expect(github.calls == ["open github.com/owner/app", "view 12"])
        let repository = try #require(session.repository)
        let saved = await store.load(repository).pullRequests
        #expect(saved?.byBranch["feature"]?.number == 12)
        session.close()
    }

    @Test func theLastPullRequestsReadShowAtOnceWhenTheRepoOpensAgain() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12, review: .approved)])
        let first = await open(repo, selecting: feature)
        first.close()

        github.hold()
        let services = services(
            repo.git, clock: clock, store: store, github: GitHubAccount(client: github))
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await github.called(3)

        #expect(try review(session, feature).pullRequest?.marker == .approved, "before gh answers")
        github.answer(open: [fakePullRequest(12, state: .merged)])
        github.release()
        await session.settled()
        #expect(try review(session, feature).pullRequest?.marker == .merged)
        session.close()
    }

    /// The list is in a second after opening; reviews and checks take one more call per PR.
    @Test func openPullRequestsShowFromTheListWhileTheirChecksAreStillComing() async throws {
        let (repo, feature) = try await fixture()
        let failed = PullRequest.Checks(failed: 1)
        github.answer(open: [fakePullRequest(12, checks: failed)])
        github.hold("view")
        let services = services(
            repo.git, clock: clock, store: store, github: GitHubAccount(client: github))
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        session.select(feature.path)
        await github.called(2)

        let row = try review(session, feature)
        await until { row.pullRequest != nil }
        #expect(row.pullRequest?.number == 12)
        #expect(row.pullRequest?.ciFailed == false, "the checks aren't in yet")
        github.release()
        await session.settled()
        #expect(row.pullRequest?.ciFailed == true)
        session.close()
    }

    @Test func checksLastReadStayWhileTheyreReadAgain() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12, checks: .init(failed: 1))])
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)
        #expect(row.pullRequest?.ciFailed == true)

        github.hold("view")
        session.reload()
        await github.called(4)
        await until { session.pullRequests?.saved.read != nil && github.reads == 2 }
        #expect(row.pullRequest?.ciFailed == true, "no flicker while the checks are read")
        github.answer(open: [fakePullRequest(12)])
        github.release()
        await session.settled()
        #expect(row.pullRequest?.ciFailed == false)
        session.close()
    }

    @Test func aPushReadsThemAgainAtMostEvery15Seconds() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12)])
        let session = await open(repo, selecting: feature)
        github.answer(open: [fakePullRequest(12, review: .approved)])

        await session.apply(RepoChange(refs: true))
        await session.apply(RepoChange(refs: true))
        #expect(refreshes(session) == 1, "a read just ran")
        try await advance(session, by: .seconds(15), once: 3, toRefresh: 2)

        #expect(github.reads == 2, "both pushes share one read")
        #expect(try review(session, feature).pullRequest?.marker == .approved)
        session.close()
    }

    @Test func reloadReadsThemAgainAtOnce() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12)])
        let session = await open(repo, selecting: feature)
        github.answer(open: [fakePullRequest(12, draft: true)])

        session.reload()
        await session.settled()

        #expect(github.reads == 2)
        #expect(try review(session, feature).pullRequest?.marker == .draft)
        session.close()
    }

    @Test func theyAreReadEveryTwoMinutesAndEvery30SecondsWhileChecksRun() async throws {
        let (repo, feature) = try await fixture()
        let running = PullRequest.Checks(passed: 1, pending: 2)
        github.answer(open: [fakePullRequest(12, checks: running)])
        let session = await open(repo, selecting: feature)
        #expect(session.pullRequests?.nextPoll == .seconds(30))

        let failed = PullRequest.Checks(passed: 1, failed: 2, failedURL: "https://ci/run/1")
        github.answer(open: [fakePullRequest(12, checks: failed)])
        try await advance(session, by: .seconds(30), once: 3, toRefresh: 2)
        #expect(try review(session, feature).pullRequest?.ciFailed == true)
        #expect(session.pullRequests?.nextPoll == .seconds(120))

        await clock.sleepers(3)
        clock.advance(by: .seconds(90))
        await clock.sleepers(1)
        #expect(refreshes(session) == 2, "nothing is running now, so it waits two minutes")
        try await advance(session, by: .seconds(30), once: 1, toRefresh: 3)
        #expect(github.reads == 3)
        session.close()
    }

    @Test func pollingWaitsWhileTheAppIsInTheBackgroundAndCatchesUpOnReturn() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12)])
        let session = await open(repo, selecting: feature)

        session.noteActivation(false)
        await clock.sleepers(3)
        clock.advance(by: .seconds(120))
        // Only the poller sleeps again: the spacing and the freshness timer are over.
        await clock.sleepers(1)
        #expect(refreshes(session) == 1)
        session.noteActivation(true)
        await until { session.pullRequests?.refreshes == 2 }
        #expect(github.reads == 2, "the data is over a minute old")
        await session.pullRequests?.idle()
        session.noteActivation(true)
        await session.pullRequests?.idle()
        #expect(refreshes(session) == 2, "fresh data isn't read again")
        session.close()
    }

    @Test func lostConnectionsAndRateLimitsBackOff() async throws {
        let (repo, feature) = try await fixture()
        github.fail(.offline)
        let session = await open(repo, selecting: feature)
        #expect(session.pullRequests?.status == .failed(.offline))
        #expect(session.services.github.status == .failed(.offline))
        #expect(session.pullRequests?.nextPoll == .seconds(60))

        github.fail(.rateLimited)
        try await advance(session, by: .seconds(60), once: 2, toRefresh: 2)
        #expect(session.pullRequests?.status == .failed(.rateLimited))
        #expect(session.pullRequests?.nextPoll == .seconds(120))
        try await advance(session, by: .seconds(120), once: 2, toRefresh: 3)
        #expect(session.pullRequests?.nextPoll == .seconds(240))

        github.answer(open: [fakePullRequest(12)])
        try await advance(session, by: .seconds(240), once: 2, toRefresh: 4)
        #expect(try review(session, feature).pullRequest?.number == 12)
        #expect(session.pullRequests?.nextPoll == .seconds(120))
        session.close()
    }

    @Test func withoutGhNothingRunsAgainUntilCheckAgain() async throws {
        let (repo, feature) = try await fixture()
        github.fail(.notInstalled)
        let session = await open(repo, selecting: feature)
        #expect(session.services.github.status == .failed(.notInstalled))
        #expect(clock.sleeperCount == 0, "nothing waits to try again")

        await session.apply(RepoChange(refs: true))
        await until { session.pullRequests?.refreshes == 2 }
        await session.settled()
        #expect(clock.sleeperCount == 0)

        github.answer(open: [fakePullRequest(12)])
        session.services.github.checkAgain()
        await until { session.services.github.retries == 1 }
        await session.refreshPullRequests()
        await until { session.pullRequests?.refreshes == 3 }
        #expect(try review(session, feature).pullRequest?.number == 12)
        #expect(session.services.github.status == .ready)
        session.close()
    }

    /// An Enterprise remote is GitHub only if gh has an account for its host; when gh can't be
    /// asked, the reason shows, the PRs read before stay, and the next read asks again.
    @Test func aHostGhCantBeAskedAboutIsntTakenForNotGitHub() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12)])
        let first = await open(repo, selecting: feature)
        first.close()

        try await repo.run("remote", "set-url", "origin", "https://code.example.com/owner/app.git")
        github.fail(.notSignedIn)
        let session = await open(repo, selecting: feature)
        #expect(session.pullRequests?.status == .failed(.notSignedIn))
        #expect(session.services.github.status == .failed(.notSignedIn))
        #expect(try review(session, feature).pullRequest?.number == 12, "kept, not wiped")

        await session.refreshPullRequests()
        await until { session.pullRequests?.refreshes == 2 }
        #expect(github.calls.count { $0 == "hosts" } == 2, "a failed answer isn't remembered")
        session.close()
    }

    @Test func aRepoWithoutAGitHubRemoteNeverAsksGh() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = await open(repo, selecting: feature)

        #expect(github.calls.isEmpty)
        #expect(session.pullRequests?.status == .notGitHub)
        #expect(clock.sleeperCount == 0)
        session.close()
    }

    @Test func turningPullRequestsOffHidesThemAndStopsReading() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12)])
        let session = await open(repo, selecting: feature)

        session.settings.showsPullRequests = false
        #expect(try review(session, feature).pullRequest == nil)
        #expect(
            !CommandCatalog.all.contains { $0.id == "pull-request-open" && $0.isEnabled(session) })
        session.reload()
        await session.settled()
        await clock.sleepers(3)
        clock.advance(by: .seconds(120))
        await clock.sleepers(1)
        #expect(refreshes(session) == 1)

        session.settings.showsPullRequests = true
        await session.refreshPullRequests()
        await until { session.pullRequests?.refreshes == 2 }
        #expect(try review(session, feature).pullRequest?.number == 12)
        session.close()
    }

    @Test func aBranchWithNoOpenPullRequestShowsItsLatestAndIsntAskedAboutAgainSoon() async throws {
        let (repo, feature) = try await fixture()
        github.answer(byHead: ["feature": fakePullRequest(9, state: .merged)])
        let session = await open(repo, selecting: feature)

        #expect(try review(session, feature).pullRequest?.marker == .merged)
        #expect(github.calls == ["open github.com/owner/app", "head feature"])
        session.reload()
        await session.settled()
        #expect(github.calls.last == "open github.com/owner/app")
        #expect(try review(session, feature).pullRequest?.number == 9)

        clock.advance(by: .seconds(600))
        session.reload()
        await session.settled()
        #expect(
            github.calls.suffix(2) == ["open github.com/owner/app", "head feature"],
            "after 10 minutes it's asked about again")
        session.close()
    }

    @Test func theTooltipSaysWhatTheMarkerMeansAndWhatIsntPushed() async throws {
        let (repo, feature) = try await fixture()
        let pushed = try await repo.sha("origin/main")
        github.answer(open: [
            fakePullRequest(
                12, review: .changesRequested, checks: .init(passed: 3, failed: 1),
                headCommit: pushed)
        ])
        let session = await open(repo, selecting: feature)

        let row = try review(session, feature)
        let pullRequest = try #require(row.pullRequest)
        #expect(row.unpushedCount == 1)
        let help = PullRequestText.help(pullRequest, unpushed: row.unpushedCount, read: nil)
        #expect(
            help
                == "#12 Count the lines\nChanges requested · Checks: 3 passed, 1 failed\n"
                + "1 local commit isn't in the pull request")
        session.close()
    }

    /// Once every file is viewed and nothing awaits the reader, the file list says what the
    /// pull request does, where the approval is decided.
    @Test func finishingTheReviewSaysWhatThePullRequestSays() async throws {
        let (repo, feature) = try await fixture()
        let pushed = try await repo.sha("origin/main")
        github.answer(open: [
            fakePullRequest(12, checks: .init(passed: 3, failed: 1), headCommit: pushed)
        ])
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)
        #expect(row.completionSummary == nil)

        session.toggleViewed("a.txt", advance: false)
        #expect(
            row.completionSummary
                == "#12 Waiting for review · Checks: 3 passed, 1 failed · "
                + "1 local commit isn't in the pull request")

        // An agent's question waits for the reader first.
        let repository = try #require(session.repository)
        let anchor = try #require(row.anchor(path: "a.txt", side: .new, lines: 1...1))
        try session.services.threads.update(repository) { threads throws(ThreadError) in
            _ = try ThreadRules.open(
                &threads, worktree: row.id, anchor: anchor, author: "claude", body: "Why a?",
                now: .now, newID: { "0000000a" })
        }
        await session.threads?.load()
        #expect(row.completionSummary == nil)
        session.close()
    }

    @Test func aPullRequestIntoAnotherBranchOffersItsBaseAndUseDiffsAgainstIt() async throws {
        let (repo, feature) = try await fixture()
        try await repo.run("update-ref", "refs/remotes/origin/release", "origin/main")
        github.answer(open: [fakePullRequest(12, base: "release")])
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)

        #expect(row.pullRequestBase?.ref == "refs/remotes/origin/release")
        let use = try #require(CommandCatalog.all.first { $0.id == "pull-request-base" })
        #expect(use.isEnabled(session))
        use.run(session)
        await session.settled()

        #expect(row.baseOverride == "refs/remotes/origin/release")
        #expect(row.parentName == "origin/release")
        #expect(row.pullRequestBase == nil)
        #expect(!use.isEnabled(session))
        session.close()
    }

    @Test func keepingTheDetectedBaseDismissesTheSuggestionForGood() async throws {
        let (repo, feature) = try await fixture()
        try await repo.run("update-ref", "refs/remotes/origin/release", "origin/main")
        github.answer(open: [fakePullRequest(12, base: "release")])
        let first = await open(repo, selecting: feature)
        #expect(try review(first, feature).pullRequestBase != nil)

        first.dismissPullRequestBase()
        #expect(try review(first, feature).pullRequestBase == nil)
        first.close()
        await first.settled()

        let again = await open(repo, selecting: feature)
        #expect(try review(again, feature).pullRequestBase == nil)
        #expect(try review(again, feature).baseOverride == nil)
        again.close()
    }

    @Test func aSuggestedBaseNamingTheParentsBranchIsNoSuggestion() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [fakePullRequest(12, base: "main")])
        let session = await open(repo, selecting: feature)
        #expect(try review(session, feature).pullRequestBase == nil)
        session.close()
    }

    @Test func aParentWhosePullRequestMergedIsStaleAndUseMovesPastIt() async throws {
        let (repo, _) = try await fixture()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        github.answer(byHead: ["b": fakePullRequest(7, head: "b", state: .merged)])
        let session = await open(repo, selecting: c)

        let row = try review(session, c)
        let stale = try #require(row.staleParent)
        #expect(stale.parent == "b")
        #expect(stale.reason == .pullRequestMerged(7))
        #expect(row.pullRequestBase == nil, "one banner at a time")
        session.setBaseOverride(stale.suggestion.ref)
        await session.settled()
        #expect(row.parentName == "origin/main")
        #expect(row.staleParent == nil)
        session.close()
    }

    @Test func theMenuOpensAndCopiesThePullRequestAndItsFailedCheck() async throws {
        let (repo, feature) = try await fixture()
        let failed = PullRequest.Checks(failed: 1, failedURL: "https://ci/run/1")
        github.answer(open: [fakePullRequest(12, checks: failed)])
        let session = await open(repo, selecting: feature)

        for id in ["pull-request-open", "pull-request-copy", "pull-request-check"] {
            #expect(try command(id).isEnabled(session), "\(id)")
        }
        try command("pull-request-open").run(session)
        try command("pull-request-check").run(session)
        #expect(
            opened.opened.map(\.absoluteString)
                == ["https://github.com/owner/app/pull/12", "https://ci/run/1"])
        session.copyPullRequestURL(of: try review(session, feature))
        #expect(session.platform?.copied.last == "https://github.com/owner/app/pull/12")

        session.select(repo.main.path)
        await session.settled()
        for id in ["pull-request-open", "pull-request-copy", "pull-request-check"] {
            #expect(try !command(id).isEnabled(session), "\(id)")
        }
        session.close()
    }
}
