import AppKit
import DiffModel
import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import SwiftUI
import TestSupport
import Testing

@testable import DiffView
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
    /// show as resolved: the list then looks as one freshly opened on the same threads does.
    @Test func resolvingAThreadAwaitingYouShowsItResolvedInThreads() async throws {
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

        let panel = ThreadsWindow(session: session, review: reviewed)
        await panel.settle()
        await session.setResolved(true, thread: id)
        await panel.settle()
        #expect(reviewed.awaitingReply.isEmpty)

        let fresh = ThreadsWindow(session: session, review: reviewed)
        await fresh.settle()
        #expect(try panel.png() == fresh.png())
    }

    /// Jump to Commit from an outdated thread far down a file shows the diff it was written on
    /// scrolled to the thread, open on its lines, not the top of the diff.
    @Test func jumpingToAThreadsCommitShowsTheThreadThere() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("a", branch: "a", from: "origin/main")
        let text = (1...120).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try await repo.commit("a.txt", text, "Add a", in: tree)
        let (session, _, _) = await threadSession(repo)
        session.select(tree.path)
        let reviewed = try #require(session.selected)
        await reviewed.loaded()
        let card = CardWindow(session: session, review: reviewed)
        await card.settle()
        let anchor = try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 90...90))
        session.draft = ThreadDraft(worktree: reviewed.id, anchor: anchor)
        await session.post("Why ninety?")
        let id = try #require(session.selectedThreadID)
        try repo.write(
            "a.txt", text.replacingOccurrences(of: "line 90\n", with: "ninety\n"), in: tree)
        reviewed.reloadDiff()
        await reviewed.loaded()
        #expect(reviewed.placedThreads.map(\.placement) == [.outdated])

        try command("thread-commit").run(session)
        let canvas = try #require(CardWindow.find(DiffCanvasView.self, in: card.window.contentView))
        let scroll = try #require(canvas.enclosingScrollView)
        #expect(await card.wait { session.openThreadMarker(for: reviewed)?.spot == .lines })
        #expect(await card.wait { canvas.openThreadRow != nil })
        let row = try #require(canvas.openThreadRow)
        let visible = scroll.contentView.bounds
        #expect(visible.minY > 0, "not the top of the diff")
        #expect(canvas.layout.top(of: row) >= visible.minY)
        #expect(canvas.layout.top(of: row) < visible.maxY)
        #expect(session.selectedThreadID == id)
        session.close()
    }

    /// The lines an outdated thread was written on are marked in its own colour: GitHub's blue
    /// for a pull request's thread, not Seam's amber.
    @Test func whatBecameOfAThreadsLinesIsMarkedInItsColour() throws {
        let anchor = ThreadAnchor(path: "a", side: .new, lines: 2...2, text: ["two"])
        let since = try #require(ThreadSince.change(of: anchor, from: "one\ntwo\n", to: "one\n2\n"))
        var thread = ReviewThread(
            id: "t", worktree: "/w", anchor: anchor, author: "octocat",
            comments: [ThreadComment(id: "c", author: "octocat", body: "Why?", date: .now)])
        func png() throws -> Data? {
            let host = NSHostingView(
                rootView: SinceChange(since: since, thread: thread, font: .systemFont(ofSize: 12))
                    .frame(width: 300))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep.representation(using: .png, properties: [:])
        }
        let seam = try png()
        thread.github = GitHubThreadSource(
            repo: GitHubRepo(host: "github.com", owner: "owner", name: "app"), pullRequest: 12,
            threadID: "PRRT_1",
            url: "u")
        #expect(try png() != seam)
    }

    /// Marking the file viewed collapses it, which folds its open thread away with it.
    @Test func markingAFileViewedClosesItsOpenThread() async throws {
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

    /// A collapsed thread is the open card's title and latest comment: clicking its title opens
    /// the card, and clicking the open card's title collapses it again.
    @Test func aThreadsTitleOpensAndCollapsesItsCard() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\n")
        let (session, review, _) = await threadSession(repo)
        let reviewed = try #require(review)
        session.draft = ThreadDraft(
            worktree: reviewed.id,
            anchor: try #require(reviewed.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await session.post("Why one?")
        let id = try #require(session.selectedThreadID)
        session.closeThread()
        let card = CardWindow(session: session, review: reviewed)
        await card.settle()
        let canvas = try #require(CardWindow.find(DiffCanvasView.self, in: card.window.contentView))
        let row = try #require(
            canvas.layout.rows.firstIndex { if case .thread = $0 { true } else { false } })
        guard case .thread(_, let marker) = canvas.layout.rows[row] else { return }
        #expect(marker.title == "Thread on line 1 · 1 comment")

        func event(_ type: NSEvent.EventType, _ point: NSPoint, in view: NSView) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: view.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: card.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let title = try #require(canvas.collapsedTitleFrame(row: row))
        let comment = NSPoint(x: title.minX + 4, y: title.maxY + 12)
        canvas.mouseDown(with: try event(.leftMouseDown, comment, in: canvas))
        await card.settle()
        #expect(session.selectedThreadID == nil, "only the title opens it, as only it closes it")
        canvas.mouseDown(
            with: try event(.leftMouseDown, NSPoint(x: title.midX, y: title.midY), in: canvas))
        #expect(await card.wait { session.selectedThreadID == id }, "the title opens it")
        let host = try #require(card.host)
        // SwiftUI only takes clicks in a window on screen; this one is invisible.
        card.window.alphaValue = 0
        card.window.orderFrontRegardless()
        defer { card.window.orderOut(nil) }
        await card.settle()
        let openTitle = NSPoint(x: 40, y: host.isFlipped ? 12 : host.bounds.height - 12)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            card.window.sendEvent(try event(type, openTitle, in: host))
        }
        #expect(await card.wait { session.selectedThreadID == nil }, "its title collapses it")
        #expect(card.host == nil)
    }
}
