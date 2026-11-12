import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// Opening in Seam what a notification is about takes it out of Notification Center, and the
/// Dock's badge counts what awaits the reader (SPEC §7.10).
@MainActor @Suite(.timeLimit(.minutes(1))) struct NotificationCleanupTests {
    /// A repo whose `feature` worktree has PR #12, checks running, and whose list has #20.
    /// The repo is returned too: its folder goes when it does.
    private func pullRequestSession() async throws -> (
        RepoSession, FakeGitHub, feature: URL, FixtureRepo
    ) {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        let github = FakeGitHub()
        github.answer(open: [fakePullRequest(12, checks: .init(pending: 1)), other(20)])
        let session = RepoSession(
            directory: repo.main,
            services: services(repo.git, github: GitHubAccount(client: github)))
        await session.open()
        await session.settled()
        session.noteActivation(false)
        return (session, github, feature, repo)
    }

    private func other(_ number: Int) -> PullRequest {
        var pullRequest = fakePullRequest(number, head: "other-\(number)")
        pullRequest.author = "anna"
        return pullRequest
    }

    @Test func openingAThreadRemovesItsNotificationAndNoOther() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let watcher = ManualWatcher()
        let (session, review, store) = await threadSession(repo, watcher: watcher)
        let reviewed = try #require(review)
        let repository = try #require(session.repository)
        let platform = try #require(session.platform)
        session.noteActivation(false)
        var ids: [String] = []
        for line in 1...2 {
            session.draft = ThreadDraft(
                worktree: reviewed.id,
                anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: line...line))
            )
            await session.post("Why?")
            ids.append(try #require(session.selectedThreadID))
            session.closeThread()
        }
        try store.update(repository) { threads throws(ThreadError) in
            for id in ids {
                try ThreadRules.reply(&threads, to: id, author: "claude", body: "So.", now: .now)
            }
        }
        watcher.send([store.file(for: repository).path])
        await until { platform.notified.count == 2 }

        session.openThread(ids[0])
        await until { !platform.removed.isEmpty }

        #expect(platform.removed == ["\(reviewed.id)|agent-\(ids[0])"])
        #expect(platform.delivered == ["\(reviewed.id)|agent-\(ids[1])"])
        session.close()
    }

    @Test func selectingAWorktreeRemovesItsPullRequestsNotifications() async throws {
        let (session, github, feature, repo) = try await pullRequestSession()
        let platform = try #require(session.platform)
        github.answer(
            open: [fakePullRequest(12, checks: .init(passed: 1)), other(20), other(21)])
        session.pullRequests?.request(.settings)
        await until { platform.notified.count == 2 }
        #expect(
            platform.delivered == [
                "\(feature.path)|checks-12-abc", "\(repo.main.path)|pr-21",
            ]
        )

        session.select(feature.path)
        await until { !platform.removed.isEmpty }

        #expect(platform.removed == ["\(feature.path)|checks-12-abc"])
        session.close()
    }

    @Test func openingAListedPullRequestRemovesItsNotification() async throws {
        let (session, github, _, repo) = try await pullRequestSession()
        let platform = try #require(session.platform)
        github.answer(
            open: [fakePullRequest(12, checks: .init(pending: 1)), other(20), other(21)])
        session.pullRequests?.request(.settings)
        await until { platform.notified.count == 1 }

        session.openListedPullRequest(21)
        await until { !platform.removed.isEmpty }

        #expect(platform.removed == ["\(repo.main.path)|pr-21"])
        session.close()
    }

    /// Restoring the selection as a repo opens isn't the reader opening that worktree.
    @Test func openingARepoRemovesNothing() async throws {
        let repo = try await FixtureRepo()
        let platform = RecordingPlatform()
        platform.notify(
            SeamNotification(
                id: "\(repo.main.path)|ready-12", group: repo.main.path, title: "main",
                body: "#12 is ready to merge", url: nil))
        let session = RepoSession(
            directory: repo.main, services: services(repo.git, platform: platform))
        await session.open()
        await session.settled()
        #expect(session.selectedID == repo.main.path)

        // Asked for by name, as a clicked notification does, it counts as opened.
        await session.handle(worktree: repo.main.path, base: nil)
        await until { !platform.removed.isEmpty }
        #expect(platform.removed == ["\(repo.main.path)|ready-12"])
        session.close()
    }

    @Test func theDockBadgeCountsWhatAwaitsTheReaderUntilTheWindowCloses() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let watcher = ManualWatcher()
        let (session, review, store) = await threadSession(repo, watcher: watcher)
        let reviewed = try #require(review)
        let repository = try #require(session.repository)
        let platform = try #require(session.platform)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(session.selectedThreadID)
        #expect(platform.badges == [])

        try store.update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: "claude", body: "So.", now: .now)
        }
        watcher.send([store.file(for: repository).path])
        await until { platform.badges == [1] }

        _ = await session.reply(to: id, "Thanks.")
        await until { platform.badges == [1, 0] }

        try store.update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: "claude", body: "Sure.", now: .now)
        }
        watcher.send([store.file(for: repository).path])
        await until { platform.badges == [1, 0, 1] }
        session.close()
        #expect(platform.badges == [1, 0, 1, 0])
    }
}
