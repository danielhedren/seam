import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// Worktree rows say what awaits the reader, and Needs You First lists those worktrees at the
/// top (SPEC §7.2).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeAttentionTests {
    private func session(_ repo: FixtureRepo) async -> RepoSession {
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        return session
    }

    private func names(_ session: RepoSession) -> [String] {
        session.sortedReviews.map(\.worktree.name)
    }

    @Test func aWorktreeWhoseAgentAnsweredComesFirstAndSaysSo() async throws {
        let repo = try await FixtureRepo()
        let quiet = try await repo.worktree("quiet", branch: "quiet", from: "origin/main")
        let answered = try await repo.worktree("answered", branch: "answered", from: "origin/main")
        try repo.write("a.txt", "a\n", in: answered)
        try repo.write("q.txt", "q\n", in: quiet)
        let session = await session(repo)
        let row = try #require(session.reviews.first { $0.id == answered.path })
        #expect(row.attention.summary == nil)

        // The reader asks; their own thread isn't theirs to act on.
        session.select(answered.path)
        await session.settled()
        session.draft = ThreadDraft(
            worktree: row.id,
            anchor: try #require(row.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why a?")
        #expect(row.attention.needsReader == false)

        // The agent answers in the other worktree's thread, as `seam reply` does.
        let repository = try #require(session.repository)
        let id = try #require(session.threads?.threads(in: row.id).first?.id)
        try session.services.threads.update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: "claude", body: "Because.", now: .now)
        }
        await session.threads?.load()
        #expect(row.attention.summary == "1 awaiting you")
        session.select(repo.main.path)
        try repo.write("q.txt", "qq\n", in: quiet)
        await session.apply(RepoChange(worktrees: [quiet.path]))
        await session.settled()
        // A worktree with work outranks the main worktree with none.
        #expect(names(session) == ["wt-answered", "wt-quiet", repo.main.lastPathComponent])

        try #require(CommandCatalog.all.first { $0.id == "sort-recent" }).run(session)
        #expect(names(session).first == repo.main.lastPathComponent)
    }

    @Test func anOpenPullRequestsFailedChecksNeedTheReader() {
        var attention = WorktreeAttention(checksFailed: true)
        #expect(attention.needsReader)
        #expect(attention.summary == "checks failed")
        attention.awaiting = 2
        #expect(attention.summary == "2 awaiting you · checks failed")
    }
}

/// Threads' Awaiting You (SPEC §7.3.2): what awaits the reader across worktrees, opened in place.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AwaitingYouTests {
    /// The main worktree selected, and an agent's question in `feature`, as `seam comment` leaves it.
    private func asked() async throws -> (RepoSession, FixtureRepo, URL, String) {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try repo.write("a.txt", "one\ntwo\n", in: feature)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let repository = try #require(session.repository)
        let thread = try session.services.threads.update(repository) {
            threads throws(ThreadError) in
            try ThreadRules.open(
                &threads, worktree: feature.path,
                anchor: ThreadAnchor(path: "a.txt", side: .new, lines: 2...2, text: ["two"]),
                author: "claude", body: "Should two stay?", now: .now)
        }
        await session.threads?.load()
        return (session, repo, feature, thread.id)
    }

    @Test func anAgentsQuestionInAnotherWorktreeOpensFromThreads() async throws {
        let (session, repo, feature, id) = try await asked()
        #expect(session.selectedID == repo.main.path)
        try command("threads").run(session)
        #expect(session.selected?.navigator == .threads)
        #expect(session.inbox.map(\.id) == [id])

        try command("next-inbox").run(session)
        await until { session.selectedThreadID == id }
        #expect(session.selectedID == feature.path)
        // Threads stays in view in the worktree it opened.
        #expect(session.selected?.navigator == .threads)
        #expect(session.selected?.placedThreads.first?.isInDiff == true)
    }

    @Test func aPullRequestNumberHasNoThousandsSeparator() {
        #expect(PullRequestText.checksFailed(2530) == "#2530 checks failed")
    }

    @Test func answeringTakesItOutOfAwaitingYou() async throws {
        // The fixture is kept: releasing it deletes its folder, and the store's file name with it.
        let (session, repo, feature, id) = try await asked()
        defer { _ = repo }
        await session.open(try #require(session.inbox.first))
        #expect(await session.reply(to: id, "Yes."))
        #expect(session.inbox.isEmpty)
        #expect(session.reviews.first { $0.id == feature.path }?.attention.needsReader == false)
    }
}
