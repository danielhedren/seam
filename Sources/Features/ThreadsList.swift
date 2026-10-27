import DiffModel
import DiffView
import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// "3 awaiting you", or the open threads here, in the header; and Copy Prompt for Agent.
struct ThreadsSummary: View {
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        let awaiting = session.inbox.count
        let open = review.openThreadCount
        Group {
            if awaiting > 0 {
                Text(String(localized: "\(awaiting) awaiting you", bundle: .module))
            } else if open > 0 {
                Text(String(localized: "\(open) open", bundle: .module))
            }
        }
        .foregroundStyle(.secondary).lineLimit(1)
    }
}

struct CopyPromptButton: View {
    let session: RepoSession

    var body: some View {
        Button {
            Task { await session.copyAgentPrompt() }
        } label: {
            Image(systemName: session.promptCopied == nil ? "doc.on.clipboard" : "checkmark")
        }
        .buttonStyle(.borderless)
        .help(
            String(
                localized: "Copy a prompt telling the agent to answer these threads",
                bundle: .module))
    }
}

/// The Threads navigator (SPEC §7.3.2): what awaits the reader across every worktree, newest
/// first, then this worktree's pull request conversation and threads by file. Picking one
/// opens its card in the diff.
struct ThreadsList: View {
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        let awaiting = session.inbox
        let shownAbove = Set(awaiting.map(\.id))
        let groups = review.threadGroups(excluding: shownAbove)
        let conversation = review.marker(for: WorktreeReview.conversationID)
        List(selection: selection) {
            if !awaiting.isEmpty {
                Section(String(localized: "Awaiting you", bundle: .module)) {
                    ForEach(awaiting) { item in
                        AwaitingRow(
                            session: session, item: item, inSelected: item.worktree == review.id
                        )
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            if let conversation {
                Section {
                    ConversationRow(marker: conversation)
                        .tag(WorktreeReview.conversationID)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(groups, id: \.path) { group in
                Section {
                    ForEach(group.threads) { placed in
                        ThreadRow(session: session, placed: placed)
                            .tag(placed.id)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(verbatim: group.path).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .overlay {
            if awaiting.isEmpty && groups.isEmpty && conversation == nil {
                ContentUnavailableView(
                    String(localized: "No threads", bundle: .module),
                    systemImage: "text.bubble",
                    description: Text(
                        "Select lines in the diff and press C to comment. Agents' answers and questions, and failed checks, show here from every worktree.",
                        bundle: .module))
            }
        }
    }

    private var selection: Binding<String?> {
        Binding(
            get: { session.selectedThreadID },
            set: { id in
                guard let id else { return }
                Task { await session.pick(thread: id) }
            })
    }
}

/// An agent's answer or question, or a pull request's failed checks, naming the worktree when
/// it isn't the one shown.
private struct AwaitingRow: View {
    let session: RepoSession
    let item: InboxItem
    let inSelected: Bool

    var body: some View {
        switch item.kind {
        case .thread(let thread):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: place("\(thread.anchor.path):\(thread.anchor.lines.lowerBound)"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    AgeText(date: item.date)
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(ThreadSnippet.text(thread)).lineLimit(2)
            }
            .padding(.vertical, 2)
        case .failedChecks(let pullRequest):
            VStack(alignment: .leading, spacing: 2) {
                if !inSelected {
                    Text(verbatim: worktreeName).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(PullRequestText.checksFailed(pullRequest.number))
                    Spacer(minLength: 4)
                    Button(String(localized: "Open Failed Check", bundle: .module)) {
                        guard let review = session.reviews.first(where: { $0.id == item.worktree })
                        else { return }
                        session.openFailedCheck(of: review)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var worktreeName: String {
        session.reviews.first { $0.id == item.worktree }?.worktree.name ?? item.worktree
    }

    private func place(_ location: String) -> String {
        inSelected ? location : "\(worktreeName) · \(location)"
    }
}

private struct ConversationRow: View {
    let marker: ThreadMarker

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Octicon.mark.image.resizable().frame(width: 12, height: 12)
                .foregroundStyle(Color(nsColor: ThreadColor.gitHubAccent))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: marker.title).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(ThreadSnippet.text(author: marker.latestAuthor, marker.latest)).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A thread of this worktree: where it is, its comment count and its latest word.
private struct ThreadRow: View {
    let session: RepoSession
    let placed: PlacedThread

    private var thread: ReviewThread { placed.thread }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if thread.source == .gitHub {
                    Octicon.mark.image.resizable().frame(width: 12, height: 12)
                } else {
                    Image(systemName: thread.isResolved ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                }
            }
            .foregroundStyle(
                thread.isResolved
                    ? AnyShapeStyle(.secondary)
                    : AnyShapeStyle(
                        Color(nsColor: ThreadColor.accent(thread.source, note: thread.isNote))))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(
                        verbatim: [lineLabel, placed.location].compactMap { $0 }.joined(
                            separator: " · ")
                    )
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: Counted.comments(thread.comments.count))
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text(ThreadSnippet.text(thread)).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .opacity(thread.isResolved ? 0.6 : 1)
        .contextMenu {
            if thread.capabilities.contains(.jumpToCommit) {
                Button(String(localized: "Jump to Commit", bundle: .module)) {
                    Task { await session.jumpToCommit(of: thread) }
                }
                .disabled(session.selected?.commitsUpTo(thread) == nil)
            }
            if thread.capabilities.contains(.openRemote) {
                Button(String(localized: "Open on GitHub", bundle: .module)) {
                    session.openOnGitHub(thread)
                }
            }
        }
    }

    private var lineLabel: String {
        if thread.github?.onFile == true { return String(localized: "Whole file", bundle: .module) }
        let lines =
            if case .lines(let now) = placed.placement { now } else { thread.anchor.lines }
        let range =
            lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)–\(lines.upperBound)"
        let place =
            thread.anchor.side == .old
            ? String(localized: "Old line \(range)", bundle: .module)
            : String(localized: "Line \(range)", bundle: .module)
        return thread.isNote ? "\(place) · \(String(localized: "Note", bundle: .module))" : place
    }
}

/// The latest word with its author in bold, as the diff's collapsed card shows it.
enum ThreadSnippet {
    static func text(_ thread: ReviewThread) -> AttributedString {
        guard let latest = thread.comments.last else { return AttributedString() }
        var author = AttributedString("\(latest.author)  ")
        author.inlinePresentationIntent = .stronglyEmphasized
        return author + CommentText.markdown(latest.body)
    }

    static func text(author: String, _ plain: String) -> AttributedString {
        var bold = AttributedString("\(author)  ")
        bold.inlinePresentationIntent = .stronglyEmphasized
        return bold + AttributedString(plain)
    }
}
