import AppKit
import DiffView
import Foundation
import GitKit
import SeamCore
import TestSupport
import Testing

@testable import Features

/// A pull request's review threads beside Seam's own (SPEC §7.9), through the real session
/// against a fake gh.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PullRequestThreadTests {
    let github = FakeGitHub()
    let store = MemoryStore()
    let threadStore = scratchThreadStore()
    let opened = OpenedURLs()

    private static func pullRequest(updated: TimeInterval = 0) -> PullRequest {
        PullRequest(
            number: 12, title: "Count the lines", url: "https://github.com/owner/app/pull/12",
            state: .open, head: "feature", headOwner: "owner", headCommit: "abc", base: "main",
            updated: Date(timeIntervalSince1970: updated))
    }

    /// A comment on `a.txt`'s one line, as GitHub reads it back.
    private static func thread(
        resolved: Bool = false, body: String = "Why a?", hunk: String = "@@ -0,0 +1 @@\n+a",
        commit: String? = nil
    ) -> GitHubReviewThread {
        GitHubReviewThread(
            id: "PRRT_1", path: "a.txt", isResolved: resolved, side: .right, lines: 1...1,
            comments: [
                .init(
                    id: 7, author: "octocat", body: body,
                    created: Date(timeIntervalSince1970: 1_792_756_800),
                    url: "https://github.com/owner/app/pull/12#discussion_r7",
                    diffHunk: hunk, commit: commit)
            ])
    }

    private func fixture() async throws -> (FixtureRepo, URL) {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        return (repo, feature)
    }

    private func open(_ repo: FixtureRepo, selecting worktree: URL) async -> RepoSession {
        var services = SeamServices(
            git: repo.git, watcher: SilentWatcher(), clock: ManualClock(), store: store,
            threads: threadStore, settings: testSettings(), github: GitHubAccount(client: github))
        let opened = opened
        services.openURL = { opened.urls.append($0) }
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        session.select(worktree.path)
        await session.settled()
        await session.selected?.loaded()
        return session
    }

    private func review(_ session: RepoSession, _ worktree: URL) throws -> WorktreeReview {
        try #require(session.reviews.first { $0.id == worktree.path })
    }

    private func command(_ id: String) throws -> SeamCommand {
        try #require(CommandCatalog.all.first { $0.id == id })
    }

    private func refresh(_ session: RepoSession) async {
        session.pullRequests?.request(.settings)
        await session.settled()
    }

    @Test func aReviewCommentShowsOnItsLineInGitHubsBlueAndCanOnlyBeRead() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)

        let row = try review(session, feature)
        let placed = try #require(row.placedThreads.first)
        #expect(placed.id == "gh-7")
        #expect(placed.placement == .lines(1...1))
        #expect(row.threadMarkers["a.txt"]?.first?.source == .gitHub)
        #expect(row.threadCountsByPath["a.txt"] == FileThreadCounts(gitHubOpen: 1))
        #expect(row.openThreadCount == 1)

        session.openThread("gh-7")
        #expect(session.openThreadMarker(for: row)?.source == .gitHub)
        #expect(try !command("resolve-thread").isEnabled(session))
        #expect(try !command("delete-thread").isEnabled(session))
        #expect(await !session.reply(to: "gh-7", "Because."))
        await session.setResolved(true, thread: "gh-7")
        await session.deleteThread("gh-7")
        #expect(row.placedThreads.map(\.thread) == [placed.thread], "nothing changed")
        #expect(session.threads?.threads.isEmpty == true, "nothing went in Seam's store")

        let open = try command("thread-on-github")
        #expect(open.isEnabled(session))
        open.run(session)
        #expect(opened.urls == [URL(string: "https://github.com/owner/app/pull/12#discussion_r7")])
        session.close()
    }

    @Test func threadsAreReadAgainWhenThePullRequestChangesAndOnReload() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)
        #expect(github.threadReads == [12])

        await refresh(session)
        #expect(github.threadReads == [12], "the PR hasn't changed")

        github.answer(open: [Self.pullRequest(updated: 60)])
        github.answer(threads: [Self.thread(resolved: true)], for: 12)
        await refresh(session)
        #expect(github.threadReads == [12, 12])
        #expect(try review(session, feature).placedThreads.first?.thread.isResolved == true)
        #expect(try review(session, feature).threadMarkers.isEmpty, "resolved ones are hidden")

        session.reload()
        await session.settled()
        #expect(github.threadReads == [12, 12, 12])
        session.close()
    }

    /// `seam threads` reads what the app wrote, without the app.
    @Test func theThreadsReadAreKeptForTheSeamCommand() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)
        let repository = try #require(session.repository)

        let saved = try threadStore.gitHubThreads(for: repository)
        #expect(saved.threads.map(\.id) == ["gh-7"])
        #expect(saved.threads.first?.worktree == feature.path)
        #expect(saved.threads.first?.github?.pullRequest == 12)
        #expect(saved.read[feature.path] != nil)
        session.close()
    }

    @Test func theLastThreadsReadShowAtOnceWhenTheRepoOpensAgain() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        await open(repo, selecting: feature).close()

        github.fail(.offline)
        github.failThreads(.offline)
        let session = await open(repo, selecting: feature)
        #expect(try review(session, feature).placedThreads.map(\.id) == ["gh-7"])
        session.close()
    }

    @Test func aFailedReadKeepsTheThreadsLastRead() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)

        github.answer(open: [Self.pullRequest(updated: 60)])
        github.failThreads(.rateLimited)
        await refresh(session)
        #expect(github.threadReads == [12, 12])
        #expect(try review(session, feature).placedThreads.map(\.id) == ["gh-7"])
        session.close()
    }

    @Test func aBranchWhosePullRequestIsGoneLosesItsThreads() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)

        github.answer(open: [])
        await refresh(session)
        #expect(try review(session, feature).placedThreads.isEmpty)
        let repository = try #require(session.repository)
        #expect(try threadStore.gitHubThreads(for: repository).threads.isEmpty)
        session.close()
    }

    @Test func aWorktreeThatLeavesItsBranchLosesItsThreads() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)
        #expect(try review(session, feature).placedThreads.map(\.id) == ["gh-7"])

        try await repo.run("-C", feature.path, "checkout", "--detach")
        // As the monitor reports it; the refresh after it is forced past the spacing.
        await session.apply(RepoChange(refs: true))
        await refresh(session)
        #expect(try review(session, feature).placedThreads.isEmpty)
        let repository = try #require(session.repository)
        #expect(try threadStore.gitHubThreads(for: repository).threads.isEmpty)
        session.close()
    }

    @Test func aRemovedWorktreesThreadsLeaveTheStore() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)

        session.select(repo.main.path)
        try await repo.run("worktree", "remove", "--force", feature.path)
        // As the monitor reports it; the refresh after it is forced past the spacing.
        await session.apply(RepoChange(refs: true))
        await refresh(session)
        let repository = try #require(session.repository)
        let saved = try threadStore.gitHubThreads(for: repository)
        #expect(saved.threads.isEmpty)
        #expect(saved.read[feature.path] == nil)
        session.close()
    }

    @Test func turningPullRequestsOffHidesTheirThreads() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread()], for: 12)
        let session = await open(repo, selecting: feature)

        session.settings.showsPullRequests = false
        #expect(try review(session, feature).placedThreads.isEmpty)
        #expect(try review(session, feature).openThreadCount == 0)
        session.settings.showsPullRequests = true
        #expect(try review(session, feature).placedThreads.map(\.id) == ["gh-7"])
        session.close()
    }

    /// Their text comes from the comment's hunk; once the worktree changes it, they're outdated.
    @Test func aCommentWhoseLinesChangedIsOutdated() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        var moved = Self.thread()
        moved.comments[0].diffHunk = "@@ -0,0 +1 @@\n+b"
        github.answer(threads: [moved], for: 12)
        let session = await open(repo, selecting: feature)
        #expect(try review(session, feature).placedThreads.first?.placement == .outdated)
        session.close()
    }

    /// a.txt reads "a" in the first commit and "b" in the second.
    private func twoCommits() async throws -> (FixtureRepo, URL, first: String, second: String) {
        let (repo, feature) = try await fixture()
        let first = try await repo.sha("feature")
        try await repo.commit("a.txt", "b\n", "Change a", in: feature)
        return (repo, feature, first, try await repo.sha("feature"))
    }

    @Test func jumpingToAnOutdatedThreadsCommitShowsItOnItsLines() async throws {
        let (repo, feature, first, _) = try await twoCommits()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread(commit: first)], for: 12)
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)
        #expect(row.placedThreads.first?.placement == .outdated)

        #expect(row.threadCountsByCommit == [.commit(first): FileThreadCounts(gitHubOpen: 1)])

        session.openThread("gh-7")
        let jump = try command("thread-commit")
        #expect(jump.isEnabled(session))
        jump.run(session)
        await until { row.placedThreads.first?.placement == .lines(1...1) }
        #expect(
            row.shownSelection == CommitSelection(newest: .commit(first), oldest: .commit(first)))
        #expect(session.selectedThreadID == "gh-7")
        #expect(session.openThreadMarker(for: row)?.lines == 1...1)
        session.close()
    }

    /// A comment is often on code from an earlier commit, so the jump keeps every one before.
    @Test func jumpingSelectsEveryCommitUpToTheThreadsOne() async throws {
        let (repo, feature, first, second) = try await twoCommits()
        try await repo.commit("a.txt", "c\n", "Change a again", in: feature)
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread(hunk: "@@ -1 +1 @@\n-a\n+b", commit: second)], for: 12)
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)

        session.openThread("gh-7")
        try command("thread-commit").run(session)
        await until { row.placedThreads.first?.placement == .lines(1...1) }
        #expect(
            row.shownSelection == CommitSelection(newest: .commit(second), oldest: .commit(first)))
        session.close()
    }

    @Test func aThreadFromACommitAfterTheOnesShownIsntCalledOutdated() async throws {
        let (repo, feature, first, second) = try await twoCommits()
        github.answer(open: [Self.pullRequest()])
        github.answer(threads: [Self.thread(hunk: "@@ -1 +1 @@\n-a\n+b", commit: second)], for: 12)
        let session = await open(repo, selecting: feature)
        let row = try review(session, feature)
        #expect(row.placedThreads.first?.placement == .lines(1...1))

        session.selectCommits(CommitSelection(newest: .commit(first), oldest: .commit(first)))
        await row.loaded()
        #expect(row.placedThreads.first?.placement == .later)
        session.close()
    }

    @Test func aThreadWhoseCommitIsntOnTheBranchCantJump() async throws {
        let (repo, feature) = try await fixture()
        github.answer(open: [Self.pullRequest()])
        github.answer(
            threads: [
                Self.thread(hunk: "@@ -0,0 +1 @@\n+z", commit: String(repeating: "f", count: 40))
            ],
            for: 12)
        let session = await open(repo, selecting: feature)
        session.openThread("gh-7")
        #expect(try !command("thread-commit").isEnabled(session))
        session.close()
    }
}
