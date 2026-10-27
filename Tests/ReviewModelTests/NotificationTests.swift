import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// Notifications (SPEC §7.10), through the real session with a recording platform.
@MainActor @Suite(.timeLimit(.minutes(1))) struct NotificationTests {
    /// An agent's answer is posted while Seam is in the background, titled with the branch and
    /// opening its thread; the reader's own words, Seam in front and a kind turned off aren't.
    @Test func anAgentsAnswerIsPostedInTheBackgroundAndOpensItsThread() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let watcher = ManualWatcher()
        let (session, review, store) = await threadSession(repo, watcher: watcher)
        let reviewed = try #require(review)
        let repository = try #require(session.repository)
        let platform = try #require(session.platform)
        session.noteActivation(false)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(reviewed.placedThreads.first?.id)
        func agentReplies(_ body: String) throws {
            try store.update(repository) { threads throws(ThreadError) in
                try ThreadRules.reply(&threads, to: id, author: "claude", body: body, now: .now)
            }
            watcher.send([store.file(for: repository).path])
        }

        try agentReplies("Because.")
        await until { platform.notified.count == 1 }
        #expect(platform.notified.first?.title == "main")
        #expect(platform.notified.first?.body == "claude: Because.")
        #expect(platform.notified.first?.url == SeamURL(path: reviewed.id, thread: id).url)

        // Neither of these is posted; the next background answer shows they were skipped.
        session.noteActivation(true)
        try agentReplies("In front.")
        await until { reviewed.placedThreads.first?.thread.comments.count == 3 }
        session.noteActivation(false)
        session.settings.notifications.remove(.agent)
        try agentReplies("Turned off.")
        await until { reviewed.placedThreads.first?.thread.comments.count == 4 }
        session.settings.notifications.insert(.agent)
        try agentReplies("Again.")
        await until { platform.notified.count == 2 }
        #expect(platform.notified.map(\.body) == ["claude: Because.", "claude: Again."])
        session.close()
    }

    /// A pull request's news while Seam is in the background: checks passing, becoming ready to
    /// merge, a review and a comment in the conversation, and merging.
    @Test func aPullRequestsNewsIsPosted() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: feature)
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        let github = FakeGitHub()
        var pullRequest = fakePullRequest(12, checks: .init(pending: 1))
        pullRequest.mergeState = .blocked
        github.answer(open: [pullRequest])
        github.answer(threads: [], viewer: "me", for: 12)
        var services = services(repo.git, github: GitHubAccount(client: github))
        let platform = RecordingPlatform()
        services.platform = platform
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        session.noteActivation(false)
        let review = try #require(session.reviews.first { $0.id == feature.path })
        await until { review.conversation != nil && review.pullRequest?.checks.pending == 1 }

        pullRequest.checks = .init(passed: 1)
        pullRequest.mergeState = .clean
        pullRequest.updated += 60
        let created = Date(timeIntervalSince1970: 1_792_756_800)
        github.answer(open: [pullRequest])
        github.answer(
            threads: [],
            conversation: [
                GitHubConversationItem(
                    id: 9, kind: .approved, author: "hubot", body: "", created: created,
                    url: "r9"),
                GitHubConversationItem(
                    id: 5, author: "octocat", body: "Ship it.", created: created + 60, url: "c5"),
                GitHubConversationItem(
                    id: 6, author: "me", body: "Thanks!", created: created + 120, url: "c6"),
            ], viewer: "me", for: 12)
        session.pullRequests?.request(.settings)
        await until { platform.notified.count == 4 }
        // The PR and its discussion are read separately, so their news can come in either order.
        #expect(
            Set(platform.notified.map(\.body)) == [
                "Checks passed on #12 Count the lines", "hubot approved #12",
                "octocat on #12: Ship it.", "#12 is ready to merge",
            ])
        #expect(Set(platform.notified.map(\.title)) == ["feature"])

        pullRequest.state = .merged
        github.answer(open: [], byHead: ["feature": pullRequest])
        session.pullRequests?.request(.settings)
        await until { platform.notified.count == 5 }
        #expect(platform.notified.last?.body == "#12 merged")
        session.close()
    }

    /// Clicking a notification opens its worktree with the thread open, from any worktree.
    @Test func openingANotificationsLinkOpensItsThread() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try repo.write("a.txt", "one\n", in: feature)
        let (session, _, store) = await threadSession(repo)
        let repository = try #require(session.repository)
        let thread = try store.update(repository) { threads throws(ThreadError) in
            try ThreadRules.open(
                &threads, worktree: feature.path,
                anchor: ThreadAnchor(path: "a.txt", side: .new, lines: 1...1, text: ["one"]),
                author: "claude", body: "Keep one?", now: .now)
        }
        await session.threads?.load()
        let link = try #require(SeamURL(path: feature.path, thread: thread.id).url)
        let request = try #require(SeamURL(link))

        await session.handle(worktree: request.path, base: request.base, thread: request.thread)
        #expect(session.selectedID == feature.path)
        #expect(session.selectedThreadID == thread.id)
        session.close()
    }
}
