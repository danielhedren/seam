import DiffView
import SeamCore
import SwiftUI

/// The thread panel (SPEC §7.7): a worktree's threads by file, open ones first, and the selected
/// one with its conversation and a reply box.
struct ThreadPanel: View {
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        let placed = review.placedThreads
        VStack(spacing: 0) {
            header(placed)
            Divider()
            if let failure = session.threads?.failure {
                Text(failure).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if placed.isEmpty {
                ContentUnavailableView(
                    String(localized: "No threads", bundle: .module),
                    systemImage: "text.bubble",
                    description: Text(
                        "Select lines in the diff and press C to comment.", bundle: .module)
                )
                .frame(maxHeight: .infinity)
            } else {
                threadList(placed)
            }
        }
    }

    private func threadList(_ placed: [PlacedThread]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups(placed), id: \.path) { group in
                    Text(group.path).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .padding(.top, 4)
                    ForEach(group.threads) { placed in
                        ThreadCard(
                            session: session, placed: placed,
                            isExpanded: session.selectedThreadID == placed.id)
                    }
                }
            }
            .padding(10)
        }
    }

    private func header(_ placed: [PlacedThread]) -> some View {
        let open = placed.filter { !$0.thread.isResolved }.count
        return HStack {
            Text("Threads", bundle: .module).font(.headline)
            if !placed.isEmpty {
                Text(String(localized: "\(open) open", bundle: .module))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button {
                session.copyAgentPrompt()
            } label: {
                Label(
                    String(localized: "Copy Prompt for Agent", bundle: .module),
                    systemImage: "doc.on.clipboard")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(
                String(
                    localized: "Copy a prompt telling the agent to answer these threads",
                    bundle: .module))
            Button {
                session.showsThreadPanel = false
            } label: {
                Label(String(localized: "Hide Threads", bundle: .module), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(
                CommandCatalog.help(
                    String(localized: "Hide Threads", bundle: .module), command: "thread-panel"))
        }
        .padding(.horizontal, 10)
        .frame(height: PaneHeader.height(session) - 1)
    }

    private func groups(_ placed: [PlacedThread]) -> [(path: String, threads: [PlacedThread])] {
        var order: [String] = []
        var byPath: [String: [PlacedThread]] = [:]
        for item in placed {
            let path = item.thread.anchor.path
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append(item)
        }
        return order.map { ($0, byPath[$0] ?? []) }
    }
}

/// The lines a thread is on, as they were when it was opened.
private struct QuotedLines: View {
    let anchor: ThreadAnchor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(anchor.text.enumerated()), id: \.offset) { offset, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(anchor.lines.lowerBound + offset)")
                        .foregroundStyle(.tertiary).frame(minWidth: 24, alignment: .trailing)
                    Text(verbatim: line.trimmingCharacters(in: .newlines)).lineLimit(1)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct ThreadCard: View {
    let session: RepoSession
    let placed: PlacedThread
    let isExpanded: Bool
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var thread: ReviewThread { placed.thread }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                session.selectedThreadID = isExpanded ? nil : thread.id
                if !isExpanded { session.showInDiff(placed) }
            } label: {
                summary.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded { conversation }
        }
        .padding(8)
        .background(
            isExpanded ? AnyShapeStyle(Color(nsColor: ThreadColor.wash)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(
                isExpanded
                    ? AnyShapeStyle(Color(nsColor: ThreadColor.accent).opacity(0.6))
                    : AnyShapeStyle(.separator))
        )
        .opacity(thread.isResolved && !isExpanded ? 0.6 : 1)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: thread.isResolved ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                    thread.isResolved
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color(nsColor: ThreadColor.accent)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: lineLabel).monospacedDigit()
                    if placed.placement == .outdated {
                        Text("Outdated", bundle: .module)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: Counted.comments(thread.comments.count))
                }
                .font(.caption).foregroundStyle(.secondary)
                // Expanded, the conversation below says it all.
                if !isExpanded { Text(snippet).lineLimit(2) }
            }
        }
    }

    private var lineLabel: String {
        let lines =
            if case .lines(let now) = placed.placement { now } else { thread.anchor.lines }
        let range =
            lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)–\(lines.upperBound)"
        return thread.anchor.side == .old
            ? String(localized: "Old line \(range)", bundle: .module)
            : String(localized: "Line \(range)", bundle: .module)
    }

    private var snippet: AttributedString {
        guard let first = thread.comments.first else { return AttributedString() }
        var author = AttributedString("\(first.author)  ")
        author.inlinePresentationIntent = .stronglyEmphasized
        return author + Self.markdown(first.body)
    }

    @ViewBuilder private var conversation: some View {
        QuotedLines(anchor: thread.anchor)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: comment.author).font(.callout.weight(.semibold))
                        AgeText(date: comment.date).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(Self.markdown(comment.body)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
        TextField(
            String(localized: "Reply", bundle: .module), text: $reply, axis: .vertical
        )
        .lineLimit(2...8)
        .textFieldStyle(.roundedBorder)
        .focused($replyFocused)
        HStack(spacing: 8) {
            Button(
                thread.isResolved
                    ? String(localized: "Reopen", bundle: .module)
                    : String(localized: "Resolve", bundle: .module)
            ) {
                Task { await session.setResolved(!thread.isResolved, thread: thread.id) }
            }
            // Away from Reply, and quiet: Undo brings a deleted thread back.
            Button(role: .destructive) {
                Task { await session.deleteThread(thread.id) }
            } label: {
                Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Delete this thread; Undo brings it back", bundle: .module))
            Spacer()
            Button(String(localized: "Reply", bundle: .module)) { send() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(String(localized: "Reply (⌘↩)", bundle: .module))
        }
        .controlSize(.small)
    }

    private func send() {
        let body = reply
        Task {
            if await session.reply(to: thread.id, body) { reply = "" }
        }
    }

    /// Inline Markdown, keeping the comment's own line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
