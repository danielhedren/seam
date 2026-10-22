import AppKit
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
    /// `c`: a draft on the selected lines, or the one being read, in the thread panel.
    func comment() {
        guard let review = selected, let target = diff.commentTarget,
            let anchor = review.anchor(path: target.path, side: target.side, lines: target.lines)
        else { return }
        draft = ThreadDraft(worktree: review.id, anchor: anchor)
        selectedThreadID = nil
        showsThreadPanel = true
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

    /// From the diff's thread row, or the panel: shows the thread there.
    func openThread(_ id: String) {
        selectedThreadID = id
        draft = nil
        showsThreadPanel = true
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
        if let here { openThread(here.id) }
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
