import AppKit
import DiffModel
import DiffView
import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct ThreadViewTests {
    /// ⌥⌘↩ in the composer posts a note: something to know about the lines that asks no answer,
    /// so it's no open work for anyone and isn't handed to the agent.
    @Test func optionCommandReturnPostsANoteThatIsntOpenWork() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, store) = await threadSession(repo)
        let reviewed = try #require(review)
        let card = CardWindow(session: session, review: reviewed)
        await card.settle()
        session.comment()
        await card.settle()
        let field = try #require(card.window.firstResponder as? NSTextView)
        field.insertText("Kept for the old API.", replacementRange: field.selectedRange())

        card.press("\r", [.command, .option])
        #expect(await card.wait { session.selectedThreadID != nil })
        let repository = try #require(session.repository)
        #expect(try store.threads(for: repository).map(\.isNote) == [true])
        #expect(reviewed.openThreadCount == 0)
        #expect(reviewed.awaitingReply.isEmpty)
        #expect(reviewed.threadMarkers["a.txt"]?.first?.isNote == true)
        session.close()
    }

    @Test func cOpensTheComposerInTheDiffAndCommandReturnPostsIt() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, _) = await threadSession(repo)
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

    /// Resolving an agent's answer from Awaiting You moves it to its file's group, where it must
    /// show as resolved: the panel then looks as one freshly opened on the same threads does.
    @Test func resolvingAThreadAwaitingYouShowsItResolvedInThePanel() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, store) = await threadSession(repo)
        let reviewed = try #require(review)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(session.selectedThreadID)
        try store.update(try #require(session.repository)) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: "claude", body: "Because.", now: .now)
        }
        await session.threads?.load()
        #expect(reviewed.awaitingReply.map(\.id) == [id])

        let panel = PanelWindow(session: session, review: reviewed)
        await panel.settle()
        await session.setResolved(true, thread: id)
        await panel.settle()
        #expect(reviewed.awaitingReply.isEmpty)

        let fresh = PanelWindow(session: session, review: reviewed)
        await fresh.settle()
        #expect(try panel.png() == fresh.png())
    }

    /// Marking the file viewed collapses it, which folds its open thread away with it: the panel
    /// is for threads the diff can't show, not ones the reader just put away.
    @Test func markingAFileViewedClosesItsOpenThreadWithoutShowingThePanel() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, _) = await threadSession(repo)
        let reviewed = try #require(review)
        let card = CardWindow(session: session, review: reviewed)
        await card.settle()
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        #expect(await card.wait { card.host != nil }, "the thread is open in the diff")

        session.toggleViewed("a.txt", advance: false)
        await card.settle()
        #expect(reviewed.collapsed == ["a.txt"])
        #expect(session.selectedThreadID == nil)
        #expect(!session.showsThreadPanel)
    }

    /// The diff pane the app shows, in a window that's never on screen, driven by keys as the
    /// reader would: `c`, typing, ⌘↩ to post, typing a reply, ⌘↩ again, Escape. After each step
    /// the card must fit its row, or its hints and buttons hang below it out of reach.
    @Test(.timeLimit(.minutes(1)), arguments: [DiffLayoutMode.unified, .split])
    func writingAThreadAndReplyingHappenInOneCardThatAlwaysFitsItsRow(_ mode: DiffLayoutMode)
        async throws
    {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, store) = await threadSession(repo)
        let reviewed = try #require(review)
        session.settings.layoutMode = mode
        let card = CardWindow(session: session, review: reviewed)
        await card.settle()

        session.comment()
        await card.settle()
        let draft = try #require(card.host)
        #expect(try card.fits())
        let field = try #require(card.window.firstResponder as? NSTextView, "the cursor is in it")
        #expect(field.isDescendant(of: draft))
        field.insertText("Why one?", replacementRange: field.selectedRange())
        #expect(session.draft?.body == "Why one?")

        card.press("\r", .command)
        #expect(await card.wait { session.selectedThreadID != nil }, "⌘↩ posts it")
        let repository = try #require(session.repository)
        #expect(try store.threads(for: repository).map(\.comments.count) == [1])
        let thread = try #require(card.host, "posting opens the new thread in the same place")
        #expect(thread !== draft)
        #expect(try card.fits())
        let posted = thread.frame.height

        let replyBox = try #require(card.textField(in: thread) as NSView?)
        card.window.makeFirstResponder(replyBox)
        let reply = try #require(card.window.firstResponder as? NSTextView)
        reply.insertText("Because.\nTwo lines, too.", replacementRange: reply.selectedRange())
        card.press("\r", .command)
        #expect(
            await card.wait { reviewed.placedThreads.first?.thread.comments.count == 2 },
            "⌘↩ sends the reply")
        #expect(try card.fits())
        #expect(try #require(card.host).frame.height > posted, "the reply made it taller")
        #expect(reply.string.isEmpty, "the box empties once it's sent")

        card.press("\u{1b}", [])
        await card.settle()
        #expect(session.selectedThreadID == nil)
        #expect(card.host == nil)
    }

    @Test func tOpensTheThreadOnTheLineAndClosesItAgain() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let (session, review, _) = await threadSession(repo)
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
}
