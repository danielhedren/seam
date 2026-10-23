import AppKit
import DiffView
import SeamCore

/// A thread being written, before it's posted (SPEC §7.7). Kept in the session, not the
/// composer, so the text survives switching worktrees and back.
struct ThreadDraft: Equatable {
    var worktree: String
    var anchor: ThreadAnchor
    var body = ""
}

/// Review threads from the reader's side: writing, answering, resolving, and handing them to an
/// agent (SPEC §7.7).
extension RepoSession {
    /// `c`: a draft on the selected lines, or the one being read, written in the diff.
    func comment() {
        guard let review = selected, let target = diff.commentTarget,
            let anchor = review.anchor(path: target.path, side: target.side, lines: target.lines)
        else { return }
        draft = ThreadDraft(worktree: review.id, anchor: anchor)
        selectedThreadID = nil
    }

    /// Where the diff opens the composer: the draft, when it's on the worktree shown.
    func draftMarker(for review: WorktreeReview) -> DraftMarker? {
        guard let draft, draft.worktree == review.id else { return nil }
        return DraftMarker(
            path: draft.anchor.path, side: draft.anchor.side, lines: draft.anchor.lines)
    }

    /// ⌘↩ in the composer; an empty draft isn't posted.
    func submitDraft() async {
        guard let body = draft?.body,
            !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        await post(body)
    }

    func post(_ body: String) async {
        guard let draft, let threads else { return }
        guard
            let thread = await threads.open(
                worktree: draft.worktree, anchor: draft.anchor, body: body)
        else { return }
        self.draft = nil
        selectedThreadID = thread.id
    }

    func reply(to id: String, _ body: String) async -> Bool {
        await threads?.reply(to: id, body: body) ?? false
    }

    func setResolved(_ resolved: Bool, thread id: String) async {
        await threads?.setResolved(resolved, id: id)
    }

    /// From the diff's thread row, `t`, or the panel: opens the thread in the diff, its file
    /// expanded. A thread the diff can't show opens in the panel instead.
    func openThread(_ id: String) {
        guard let review = selected, let placed = review.placedThreads.first(where: { $0.id == id })
        else { return }
        selectedThreadID = id
        draft = nil
        let path = placed.thread.anchor.path
        if placed.isInDiff, review.collapsed.contains(path) { review.toggleCollapsed(path) }
        if !placed.isInDiff { showsThreadPanel = true }
    }

    func closeThread() {
        selectedThreadID = nil
        diff.focus()
    }

    /// The diff found no row for the open thread; the panel is where it can be read.
    func noteOpenThreadHidden(_ hidden: Bool) {
        guard hidden != openThreadIsHidden else { return }
        openThreadIsHidden = hidden
        if hidden { showsThreadPanel = true }
    }

    /// What the diff opens: the selected thread, which shows even when resolved ones are hidden.
    func openThreadMarker(for review: WorktreeReview) -> ThreadMarker? {
        guard let id = selectedThreadID else { return nil }
        return review.marker(for: id)
    }

    /// `t`: the thread on the line being read, if there is one.
    func openThreadAtCursor() {
        guard let review = selected, let location = diff.readingLocation else { return }
        let here = review.placedThreads.first { placed in
            guard placed.thread.anchor.path == location.path,
                case .lines(let lines) = placed.placement
            else { return false }
            return lines.contains(location.line)
        }
        guard let here else { return }
        if here.id == selectedThreadID { closeThread() } else { openThread(here.id) }
    }

    /// Review › Delete Thread; Undo puts it back where it was.
    func deleteThread(_ id: String) async {
        guard let threads, let (thread, index) = await threads.delete(id: id) else { return }
        if selectedThreadID == id { selectedThreadID = nil }
        let name = String(localized: "Delete Thread", bundle: .module)
        // Redo has to be registered while the undo runs, so only the store write waits.
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                session.undoManager?.registerUndo(withTarget: session) { session in
                    MainActor.assumeIsolated {
                        _ = Task { await session.deleteThread(thread.id) }
                    }
                }
                session.undoManager?.setActionName(name)
                session.restoringThreads = Task {
                    await threads.restore(thread, at: index)
                    session.selectedThreadID = thread.id
                }
            }
        }
        undoManager?.setActionName(name)
    }

    func showInDiff(_ placed: PlacedThread) {
        guard case .lines(let lines) = placed.placement else { return }
        diff.scroll(
            toLine: lines.lowerBound, inFile: placed.thread.anchor.path,
            side: placed.thread.anchor.side)
    }

    /// Review › Copy Prompt for Agent: how the agent in this worktree reads and answers.
    func copyAgentPrompt(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(Self.agentPrompt, forType: .string)
    }

    static let agentPrompt = """
        I've left review comments on your changes in Seam. Run `seam threads` in this worktree \
        to read the open threads. For each one, make the change it asks for, or explain why \
        not, and answer with `seam reply <id> "..." --as <your name>` saying what you did. \
        Don't resolve threads you didn't open; I resolve mine. `seam --help` lists the other \
        commands.
        """
}
