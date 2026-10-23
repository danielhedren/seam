import AppKit
import DiffView
import Foundation
import GitKit
import SeamCore
import TestSupport
import Testing

@testable import Features

@MainActor @Suite struct ThreadTests {
    private func session(_ repo: FixtureRepo, watcher: any FileWatcher = SilentWatcher()) async
        -> (RepoSession, WorktreeReview?, ThreadStore)
    {
        let store = scratchThreadStore()
        let session = RepoSession(
            directory: repo.main,
            services: SeamServices(
                git: repo.git, watcher: watcher, clock: ManualClock(), store: MemoryStore(),
                threads: store, settings: testSettings()))
        await session.open()
        await session.settled()
        return (session, session.selected, store)
    }

    @Test func aCommentSitsOnItsLinesAndFollowsThemThroughEdits() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        let (session, review, _) = await session(repo)
        let reviewed = try #require(review)
        let anchor = try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 2...2))
        #expect(anchor.text == ["two"])

        session.draft = ThreadDraft(worktree: reviewed.id, anchor: anchor)
        await session.post("Why two?")
        #expect(session.draft == nil)
        #expect(reviewed.placedThreads.map(\.placement) == [.lines(2...2)])
        #expect(reviewed.content?.threads["a.txt"]?.map(\.latest) == ["Why two?"])

        try repo.write("a.txt", "zero\none\ntwo\nthree\n")
        reviewed.reloadDiff()
        await reviewed.loaded()
        #expect(reviewed.placedThreads.map(\.placement) == [.lines(3...3)])

        try repo.write("a.txt", "zero\none\n2\nthree\n")
        reviewed.reloadDiff()
        await reviewed.loaded()
        #expect(reviewed.placedThreads.map(\.placement) == [.outdated])
        #expect(reviewed.content?.threads.isEmpty == true)
    }

    @Test func cOpensTheComposerInTheDiffAndCommandReturnPostsIt() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, _) = await session(repo)
        let reviewed = try #require(review)
        try showDiff(session)

        session.comment()

        let draft = try #require(session.draft)
        #expect(!session.showsThreadPanel)
        #expect(
            session.draftMarker(for: reviewed)
                == DraftMarker(path: "a.txt", side: .new, lines: draft.anchor.lines))
        await session.submitDraft()
        #expect(session.draft != nil, "an empty draft isn't posted")
        session.draft?.body = "Why two?"
        await session.submitDraft()
        #expect(session.draft == nil)
        #expect(session.draftMarker(for: reviewed) == nil)
        #expect(reviewed.placedThreads.map(\.thread.comments.first?.body) == ["Why two?"])
    }

    @Test func openingAThreadShowsItInTheDiffAndAnOutdatedOneInThePanel() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, _) = await session(repo)
        let reviewed = try #require(review)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(session.selectedThreadID)
        session.closeThread()
        session.toggleCollapsed("a.txt")

        session.openThread(id)
        #expect(session.selectedThreadID == id)
        #expect(!session.showsThreadPanel, "the diff is where it's read")
        #expect(!reviewed.collapsed.contains("a.txt"), "its file opens for it")
        #expect(session.openThreadMarker(for: reviewed)?.id == id)

        await session.setResolved(true, thread: id)
        #expect(reviewed.threadMarkers["a.txt"] == nil)
        #expect(session.openThreadMarker(for: reviewed)?.id == id, "resolved, it stays open")

        try repo.write("a.txt", "zero\n")
        reviewed.reloadDiff()
        await reviewed.loaded()
        session.closeThread()
        session.openThread(id)
        #expect(session.showsThreadPanel, "outdated, only the panel can show it")
        #expect(session.openThreadMarker(for: reviewed) == nil)
    }

    @Test func tOpensTheThreadOnTheLineAndClosesItAgain() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let (session, review, _) = await session(repo)
        let reviewed = try #require(review)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why?")
        let id = try #require(session.selectedThreadID)
        session.closeThread()
        _ = try showDiff(session)

        session.openThreadAtCursor()
        #expect(session.selectedThreadID == id)
        session.openThreadAtCursor()
        #expect(session.selectedThreadID == nil)
    }

    @Test func deletingAThreadRemovesItAndUndoAndRedoFollow() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, store) = await session(repo)
        let reviewed = try #require(review)
        let repository = try #require(session.repository)
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(session.selectedThreadID)

        undo.beginUndoGrouping()
        await session.deleteThread(id)
        undo.endUndoGrouping()
        #expect(reviewed.placedThreads.isEmpty)
        #expect(session.selectedThreadID == nil)
        #expect(try store.threads(for: repository).isEmpty)
        #expect(undo.undoActionName == "Delete Thread")

        undo.undo()
        await session.restoringThreads?.value
        #expect(reviewed.placedThreads.map(\.id) == [id])
        #expect(session.selectedThreadID == id)
        #expect(undo.canRedo)
    }

    @Test func anUnpostedDraftAndItsTextSurviveSwitchingWorktrees() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        let (session, review, _) = await session(repo)
        let reviewed = try #require(review)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        session.draft?.body = "Half a thought"

        session.select(other.path)
        session.select(reviewed.id)

        #expect(session.draft?.worktree == reviewed.id)
        #expect(session.draft?.body == "Half a thought")
    }

    @Test func anAgentsReplyArrivesWithoutAReload() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let watcher = ManualWatcher()
        let (session, review, store) = await session(repo, watcher: watcher)
        let reviewed = try #require(review)
        let repository = try #require(session.repository)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why?")
        let id = try #require(reviewed.placedThreads.first?.id)

        // What `seam reply` does from the agent's shell.
        try store.update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: "claude", body: "Because.", now: .now)
        }
        watcher.send([store.file(for: repository).path])

        await until { reviewed.placedThreads.first?.thread.comments.count == 2 }
        #expect(reviewed.content?.threads["a.txt"]?.first?.latestAuthor == "claude")
    }

    @Test func theReaderResolvesAnyThreadAndResolvedOnesLeaveTheDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let (session, review, store) = await session(repo)
        let reviewed = try #require(review)
        let repository = try #require(session.repository)
        let anchor = try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1))
        let agents = try store.update(repository) { threads throws(ThreadError) in
            try ThreadRules.open(
                &threads, worktree: reviewed.id, anchor: anchor, author: "claude",
                body: "Consider a constant.", now: .now)
        }
        await session.threads?.load()
        session.draft = ThreadDraft(worktree: reviewed.id, anchor: anchor)
        await session.post("Mine.")
        let mine = try #require(reviewed.placedThreads.first { $0.thread.author == "you" })

        await session.setResolved(true, thread: mine.id)
        #expect(session.threads?.failure == nil)
        #expect(reviewed.content?.threads["a.txt"]?.map(\.id) == [agents.id])
        await session.setResolved(true, thread: agents.id)
        let resolved = Set(reviewed.placedThreads.filter(\.thread.isResolved).map(\.id))
        #expect(resolved == [mine.id, agents.id])
        #expect(reviewed.content?.threads["a.txt"] == nil)
        session.settings.showsResolvedThreads = true
        #expect(reviewed.content?.threads["a.txt"]?.count == 2)
    }

    @Test func reloadingUnchangedThreadsKeepsPlacementsCached() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let (session, review, _) = await session(repo)
        let reviewed = try #require(review)
        let threads = try #require(session.threads)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why?")
        await threads.load()
        let version = threads.version

        await threads.load()

        #expect(threads.version == version)
        #expect(reviewed.placedThreads.count == 1)
    }

    @Test func theAgentPromptSaysHowToReadAndAnswer() async throws {
        let repo = try await FixtureRepo()
        let (session, _, _) = await session(repo)
        let pasteboard = NSPasteboard(name: .init("seam-tests-\(UUID().uuidString)"))
        session.copyAgentPrompt(to: pasteboard)
        let prompt = try #require(pasteboard.string(forType: .string))
        #expect(prompt.contains("seam threads") && prompt.contains("seam reply"))
        #expect(prompt.contains("Don't resolve threads you didn't open"))
        pasteboard.releaseGlobally()
    }
}
