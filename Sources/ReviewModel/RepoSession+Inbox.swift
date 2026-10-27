import Foundation
import GitKit
import SeamCore

/// Something in one of the repo's worktrees that's the reader's to act on (SPEC §7.3.2).
package struct InboxItem: Identifiable, Equatable {
    package enum Kind: Equatable {
        /// A thread whose latest word is an agent's: an answer or a question.
        case thread(ReviewThread)
        case failedChecks(PullRequest)
    }

    package var worktree: String
    package var kind: Kind
    package var date: Date

    package var id: String {
        switch kind {
        case .thread(let thread): thread.id
        case .failedChecks: "checks:\(worktree)"
        }
    }
}

/// The Threads navigator's first part: what awaits the reader across every worktree, newest
/// first, and opening it where it is.
extension RepoSession {
    package var inbox: [InboxItem] {
        reviews.filter { !$0.worktree.isMissing }.flatMap(inboxItems)
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    private func inboxItems(in review: WorktreeReview) -> [InboxItem] {
        let reader =
            threads?.knownReader(in: review.id) ?? ReviewerIdentity(name: ReviewThread.reader)
        let awaiting = (threads?.threads(in: review.id) ?? []).filter(reader.awaitsReply)
        var items: [InboxItem] = awaiting.map { thread in
            InboxItem(
                worktree: review.id, kind: .thread(thread),
                date: thread.comments.last?.date ?? .distantPast)
        }
        if review.attention.checksFailed, let pullRequest = review.pullRequest {
            items.append(
                InboxItem(
                    worktree: review.id, kind: .failedChecks(pullRequest),
                    date: pullRequest.updated))
        }
        return items
    }

    /// Go › Show Threads, and the toolbar's Threads button: the Threads navigator, or back to
    /// Files from it.
    package var showsThreads: Bool {
        get { selected?.navigator == .threads }
        set { selected?.navigator = newValue ? .threads : .files }
    }

    /// Picks the item's worktree, keeping Threads shown there, and opens its thread's card in
    /// the diff.
    package func open(_ item: InboxItem) async {
        select(item.worktree)
        guard let review = selected, review.id == item.worktree else { return }
        review.navigator = .threads
        guard case .thread(let thread) = item.kind else { return }
        await review.loaded()
        openThread(thread.id)
        if let placed = review.placedThreads.first(where: { $0.id == thread.id }),
            placed.isInDiff
        {
            showInDiff(placed)
        }
    }

    /// A row of the Threads navigator: what awaits the reader opens where it is, and this
    /// worktree's conversation or thread opens its card in the diff.
    package func pick(thread id: String) async {
        if let item = inbox.first(where: { $0.id == id }) {
            await open(item)
            return
        }
        openThread(id)
        if let placed = selected?.placedThreads.first(where: { $0.id == id }) { showInDiff(placed) }
    }

    /// Go › Next Awaiting You: the item after the open thread, wrapping.
    package func openNextInInbox() async {
        let items = inbox
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedThreadID }
        await open(items[current.map { ($0 + 1) % items.count } ?? 0])
    }
}
