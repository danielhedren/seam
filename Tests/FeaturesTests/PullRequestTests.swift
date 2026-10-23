import AppKit
import Foundation
import GitKit
import SeamCore
import Synchronization
import TestSupport
import Testing

@testable import Features

/// Stands in for gh: answers from what the test set, records every call, and can hold calls
/// until released.
final class FakeGitHub: GitHubClient, Sendable {
    private struct State {
        var open: [PullRequest] = []
        var byHead: [String: PullRequest] = [:]
        var error: GitHubError?
        var calls: [String] = []
        var holding = false
        /// Holds only calls whose name starts with this, when set.
        var holdingPrefix: String?
        var held: [CheckedContinuation<Void, Never>] = []
        var watchers: [(count: Int, resume: @Sendable () -> Void)] = []
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    /// Reads of the repo's open list: one per refresh that reached gh.
    var reads: Int { calls.count { $0.hasPrefix("open ") } }

    func answer(open: [PullRequest] = [], byHead: [String: PullRequest] = [:]) {
        state.withLock {
            $0.open = open
            $0.byHead = byHead
            $0.error = nil
        }
    }

    func fail(_ error: GitHubError) {
        state.withLock { $0.error = error }
    }

    func hold(_ prefix: String? = nil) {
        state.withLock {
            $0.holding = true
            $0.holdingPrefix = prefix
        }
    }

    func release() {
        let held = state.withLock { state in
            state.holding = false
            defer { state.held = [] }
            return state.held
        }
        for continuation in held { continuation.resume() }
    }

    /// Returns once gh has been called `count` times.
    func called(_ count: Int) async {
        await waitCancellably { resume in
            let done = state.withLock { state in
                if state.calls.count >= count { return true }
                state.watchers.append((count, resume))
                return false
            }
            if done { resume() }
        }
    }

    private func call(_ name: String) async throws(GitHubError) {
        await withCheckedContinuation { continuation in
            let (holding, ready) = state.withLock { state in
                state.calls.append(name)
                let holds = state.holding && state.holdingPrefix.map(name.hasPrefix) != false
                if holds { state.held.append(continuation) }
                let count = state.calls.count
                let ready = state.watchers.filter { $0.count <= count }.map(\.resume)
                state.watchers.removeAll { $0.count <= count }
                return (holds, ready)
            }
            for watcher in ready { watcher() }
            if !holding { continuation.resume() }
        }
        if let error = state.withLock({ $0.error }) { throw error }
    }

    func hosts() async throws(GitHubError) -> [String] {
        try await call("hosts")
        return ["github.com"]
    }

    /// Without reviews and checks, like gh's list: they come from `pullRequest(_:in:)`.
    func openPullRequests(in repo: GitHubRepo) async throws(GitHubError) -> [PullRequest] {
        try await call("open \(repo.slug)")
        return state.withLock { $0.open }.map { summary in
            var summary = summary
            summary.review = .none
            summary.checks = .init()
            return summary
        }
    }

    func pullRequest(_ number: Int, in repo: GitHubRepo) async throws(GitHubError)
        -> PullRequest
    {
        try await call("view \(number)")
        let found = state.withLock { state in
            (state.open + state.byHead.values).first { $0.number == number }
        }
        guard let found else { throw .failed("no pull request \(number)") }
        return found
    }

    func latestPullRequest(from branch: String, in repo: GitHubRepo) async throws(GitHubError)
        -> PullRequest?
    {
        try await call("head \(branch)")
        return state.withLock { $0.byHead[branch] }
    }
}

@MainActor
final class OpenedURLs {
    var urls: [URL] = []
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PullRequestTests {
    let github = FakeGitHub()
    let clock = ManualClock()
    let store = MemoryStore()
    let opened = OpenedURLs()

    private static func pullRequest(
        _ number: Int, head: String = "feature", state: PullRequest.State = .open,
        draft: Bool = false, review: PullRequest.Review = .none,
        checks: PullRequest.Checks = .init(), base: String = "main", headCommit: String = "abc"
    ) -> PullRequest {
        PullRequest(
            number: number, title: "Count the lines",
            url: "https://github.com/owner/app/pull/\(number)", state: state, isDraft: draft,
            head: head, headOwner: "owner", headCommit: headCommit, base: base, review: review,
            checks: checks, updated: Date(timeIntervalSince1970: 0))
    }

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
        var services = SeamServices(
            git: repo.git, watcher: SilentWatcher(), clock: clock, store: store,
            threads: scratchThreadStore(), settings: testSettings(),
            github: GitHubAccount(client: github))
        let opened = opened
        services.openURL = { opened.urls.append($0) }
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
        github.answer(open: [Self.pullRequest(12)])

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
        github.answer(open: [Self.pullRequest(12, review: .approved)])
        let first = await open(repo, selecting: feature)
        first.close()

        github.hold()
        let services = SeamServices(
            git: repo.git, watcher: SilentWatcher(), clock: clock, store: store,
            threads: scratchThreadStore(), settings: testSettings(),
            github: GitHubAccount(client: github))
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await github.called(3)

        #expect(try review(session, feature).pullRequest?.marker == .approved, "before gh answers")
        github.answer(open: [Self.pullRequest(12, state: .merged)])
        github.release()
        await session.settled()
        #expect(try review(session, feature).pullRequest?.marker == .merged)
        session.close()
    }

    /// The list is in a second after opening; reviews and checks take one more call per PR.
    @Test func openPullRequestsShowFromTheListWhileTheirChecksAreStillComing() async throws {
        let (repo, feature) = try await fixture()
        let failed = PullRequest.Checks(failed: 1)
        github.answer(open: [Self.pullRequest(12, checks: failed)])
        github.hold("view")
        var services = SeamServices(
            git: repo.git, watcher: SilentWatcher(), clock: clock, store: store,
            threads: scratchThreadStore(), settings: testSettings(),
            github: GitHubAccount(client: github))
        services.openURL = { _ in }
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
        github.answer(open: [Self.pullRequest(12, checks: .init(failed: 1))])
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)
        #expect(row.pullRequest?.ciFailed == true)

        github.hold("view")
        session.reload()
        await github.called(4)
        await until { session.pullRequests?.saved.read != nil && github.reads == 2 }
        #expect(row.pullRequest?.ciFailed == true, "no flicker while the checks are read")
        github.answer(open: [Self.pullRequest(12)])
        github.release()
        await session.settled()
        #expect(row.pullRequest?.ciFailed == false)
        session.close()
    }

    @Test func aPushReadsThemAgainAtMostEvery15Seconds() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest(12)])
        let session = await open(repo, selecting: feature)
        github.answer(open: [Self.pullRequest(12, review: .approved)])

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
        github.answer(open: [Self.pullRequest(12)])
        let session = await open(repo, selecting: feature)
        github.answer(open: [Self.pullRequest(12, draft: true)])

        session.reload()
        await session.settled()

        #expect(github.reads == 2)
        #expect(try review(session, feature).pullRequest?.marker == .draft)
        session.close()
    }

    @Test func theyAreReadEveryTwoMinutesAndEvery30SecondsWhileChecksRun() async throws {
        let (repo, feature) = try await fixture()
        let running = PullRequest.Checks(passed: 1, pending: 2)
        github.answer(open: [Self.pullRequest(12, checks: running)])
        let session = await open(repo, selecting: feature)
        #expect(session.pullRequests?.nextPoll == .seconds(30))

        let failed = PullRequest.Checks(passed: 1, failed: 2, failedURL: "https://ci/run/1")
        github.answer(open: [Self.pullRequest(12, checks: failed)])
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
        github.answer(open: [Self.pullRequest(12)])
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

        github.answer(open: [Self.pullRequest(12)])
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

        github.answer(open: [Self.pullRequest(12)])
        session.services.github.checkAgain()
        await until { session.services.github.retries == 1 }
        session.refreshPullRequests()
        await until { session.pullRequests?.refreshes == 3 }
        #expect(try review(session, feature).pullRequest?.number == 12)
        #expect(session.services.github.status == .ready)
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
        github.answer(open: [Self.pullRequest(12)])
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
        session.refreshPullRequests()
        await until { session.pullRequests?.refreshes == 2 }
        #expect(try review(session, feature).pullRequest?.number == 12)
        session.close()
    }

    @Test func aBranchWithNoOpenPullRequestShowsItsLatestAndIsntAskedAboutAgainSoon() async throws {
        let (repo, feature) = try await fixture()
        github.answer(byHead: ["feature": Self.pullRequest(9, state: .merged)])
        let session = await open(repo, selecting: feature)

        #expect(try review(session, feature).pullRequest?.marker == .merged)
        #expect(github.calls == ["open github.com/owner/app", "head feature"])
        session.reload()
        await session.settled()
        #expect(github.calls.last == "open github.com/owner/app")
        #expect(try review(session, feature).pullRequest?.number == 9)
        session.close()
    }

    @Test func theTooltipSaysWhatTheMarkerMeansAndWhatIsntPushed() async throws {
        let (repo, feature) = try await fixture()
        let pushed = try await repo.sha("origin/main")
        github.answer(open: [
            Self.pullRequest(
                12, review: .changesRequested, checks: .init(passed: 3, failed: 1),
                headCommit: pushed)
        ])
        let session = await open(repo, selecting: feature)

        let row = try review(session, feature)
        let pullRequest = try #require(row.pullRequest)
        #expect(row.unpushedCount == 1)
        let help = PullRequestBadge.help(pullRequest, unpushed: row.unpushedCount, read: nil)
        #expect(
            help
                == "#12 Count the lines\nChanges requested · Checks: 3 passed, 1 failed\n"
                + "1 local commit isn't in the pull request")
        session.close()
    }

    @Test func aPullRequestIntoAnotherBranchOffersItsBaseAndUseDiffsAgainstIt() async throws {
        let (repo, feature) = try await fixture()
        try await repo.run("update-ref", "refs/remotes/origin/release", "origin/main")
        github.answer(open: [Self.pullRequest(12, base: "release")])
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
        github.answer(open: [Self.pullRequest(12, base: "release")])
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
        github.answer(open: [Self.pullRequest(12, base: "main")])
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
        github.answer(byHead: ["b": Self.pullRequest(7, head: "b", state: .merged)])
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
        github.answer(open: [Self.pullRequest(12, checks: failed)])
        let session = await open(repo, selecting: feature)
        func command(_ id: String) throws -> SeamCommand {
            try #require(CommandCatalog.all.first { $0.id == id })
        }

        for id in ["pull-request-open", "pull-request-copy", "pull-request-check"] {
            #expect(try command(id).isEnabled(session), "\(id)")
        }
        try command("pull-request-open").run(session)
        try command("pull-request-check").run(session)
        #expect(
            opened.urls.map(\.absoluteString)
                == ["https://github.com/owner/app/pull/12", "https://ci/run/1"])
        let pasteboard = NSPasteboard(name: .init("seam-tests-\(UUID())"))
        session.copyPullRequestURL(of: try review(session, feature), to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "https://github.com/owner/app/pull/12")

        let actions = RowActions.actions(for: try review(session, feature), in: session)
        #expect(
            actions.last?.map(\.title) == ["Open Pull Request in Browser", "Copy Pull Request URL"])

        session.select(repo.main.path)
        await session.settled()
        for id in ["pull-request-open", "pull-request-copy", "pull-request-check"] {
            #expect(try !command(id).isEnabled(session), "\(id)")
        }
        session.close()
    }
}
