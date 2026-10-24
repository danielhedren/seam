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
        let awaiting = review.awaitingReply
        let waiting = Set(awaiting.map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                // Answers and questions come first: reviewing them is the reader's next step.
                if !awaiting.isEmpty {
                    Text(String(localized: "Awaiting you (\(awaiting.count))", bundle: .module))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(awaiting) { placed in
                        ThreadCard(
                            session: session, placed: placed,
                            isSelected: session.selectedThreadID == placed.id, showsPath: true)
                    }
                }
                ForEach(groups(placed.filter { !waiting.contains($0.id) }), id: \.path) { group in
                    Text(group.path).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .padding(.top, 4)
                    ForEach(group.threads) { placed in
                        ThreadCard(
                            session: session, placed: placed,
                            isSelected: session.selectedThreadID == placed.id)
                    }
                }
            }
            .padding(10)
        }
    }

    private func header(_ placed: [PlacedThread]) -> some View {
        let open = placed.filter { !$0.thread.isResolved && !$0.thread.isNote }.count
        return HStack {
            Text("Threads", bundle: .module).font(.headline)
            if !placed.isEmpty {
                Text(String(localized: "\(open) open", bundle: .module))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button {
                Task { await session.copyAgentPrompt() }
            } label: {
                Label(
                    String(localized: "Copy Prompt for Agent", bundle: .module),
                    systemImage: session.promptCopied == nil ? "doc.on.clipboard" : "checkmark")
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
            let path = item.path
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append(item)
        }
        return order.map { ($0, byPath[$0] ?? []) }
    }
}

/// The lines a thread is on, as they were when it was opened. A long quote shows its first lines
/// and a row that expands it; the state goes with the card's conversation when it collapses.
struct QuotedLines: View {
    let anchor: ThreadAnchor
    @State private var showsAll = false

    static let maxRows = 8

    /// How many lines show, and how many the last row says are left out.
    static func visible(_ count: Int, showsAll: Bool) -> (shown: Int, hidden: Int) {
        guard !showsAll, count > maxRows else { return (count, 0) }
        return (maxRows - 1, count - (maxRows - 1))
    }

    var body: some View {
        let (shown, hidden) = Self.visible(anchor.text.count, showsAll: showsAll)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(anchor.text.prefix(shown).enumerated()), id: \.offset) { offset, line in
                row {
                    Text(verbatim: "\(anchor.lines.lowerBound + offset)")
                        .foregroundStyle(.tertiary)
                } text: {
                    Text(verbatim: line.trimmingCharacters(in: .newlines)).lineLimit(1)
                }
            }
            if hidden > 0 {
                Button {
                    showsAll = true
                } label: {
                    row {
                        EmptyView()
                    } text: {
                        Text("\(hidden) more lines", bundle: .module).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    /// The number column is as wide as the quote's last number, so every row's text lines up.
    private func row(
        @ViewBuilder number: () -> some View, @ViewBuilder text: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack(alignment: .trailing) {
                Text(verbatim: "\(anchor.lines.lowerBound + max(anchor.text.count - 1, 0))")
                    .hidden()
                number()
            }
            .frame(minWidth: 24, alignment: .trailing)
            text()
        }
    }
}

/// A thread in the panel's overview. Picking one opens it in the diff; only a thread the diff
/// can't show (outdated, or its file not in the diff) opens its conversation here.
struct ThreadCard: View {
    let session: RepoSession
    let placed: PlacedThread
    let isSelected: Bool
    /// Outside its file's group, the card names the file.
    var showsPath = false
    @State private var reply = ""

    private var thread: ReviewThread { placed.thread }
    /// The picked thread always opens here, whether or not the diff can show it too, so a
    /// click does the same thing every time.
    private var isExpanded: Bool { isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    if isSelected {
                        session.closeThread()
                    } else {
                        session.openThread(thread.id)
                    }
                } label: {
                    summary.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { menu }
                if isExpanded { ThreadActions(session: session, thread: thread).font(.caption) }
            }
            if isExpanded { conversation }
        }
        .padding(8)
        .background(
            isSelected
                ? AnyShapeStyle(
                    Color(nsColor: ThreadColor.wash(thread.source, note: thread.isNote)))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7).strokeBorder(
                isSelected
                    ? AnyShapeStyle(
                        Color(nsColor: ThreadColor.accent(thread.source, note: thread.isNote))
                            .opacity(0.6))
                    : AnyShapeStyle(.separator))
        )
        .opacity(thread.isResolved && !isSelected ? 0.6 : 1)
    }

    @ViewBuilder private var menu: some View {
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

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if thread.source == .gitHub {
                    Octicon.mark.image.resizable().frame(width: 12, height: 12)
                } else {
                    Image(systemName: thread.isResolved ? "checkmark.circle.fill" : "circle")
                }
            }
            .foregroundStyle(
                thread.isResolved
                    ? AnyShapeStyle(.secondary)
                    : AnyShapeStyle(
                        Color(nsColor: ThreadColor.accent(thread.source, note: thread.isNote))))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: showsPath ? "\(placed.path) · \(lineLabel)" : lineLabel)
                        .monospacedDigit().lineLimit(1).truncationMode(.middle)
                    if thread.isNote {
                        Text("Note", bundle: .module)
                            .padding(.horizontal, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    if let location = Self.location(placed) {
                        Text(verbatim: location)
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
        if thread.github?.onFile == true { return String(localized: "Whole file", bundle: .module) }
        let lines =
            if case .lines(let now) = placed.placement { now } else { thread.anchor.lines }
        let range =
            lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)–\(lines.upperBound)"
        return thread.anchor.side == .old
            ? String(localized: "Old line \(range)", bundle: .module)
            : String(localized: "Line \(range)", bundle: .module)
    }

    /// Where a thread is when that isn't on its lines in the diff; nil when it is.
    static func location(_ placed: PlacedThread) -> String? {
        switch placed.placement {
        case .lines: nil
        case .outdated: String(localized: "Outdated", bundle: .module)
        case .later: String(localized: "From a later commit", bundle: .module)
        case .notShown:
            placed.thread.github?.onFile == true
                ? nil : String(localized: "Not in this diff", bundle: .module)
        }
    }

    /// The latest word, as the diff's row shows it, so an agent's answer is visible here too.
    private var snippet: AttributedString {
        guard let latest = thread.comments.last else { return AttributedString() }
        var author = AttributedString("\(latest.author)  ")
        author.inlinePresentationIntent = .stronglyEmphasized
        return author + CommentText.markdown(latest.body)
    }

    private var conversation: some View {
        let canReply = thread.capabilities.contains(.reply)
        return ThreadCardLayout(
            session: session, font: .systemFont(ofSize: NSFont.systemFontSize), thread: thread,
            showsQuote: true, text: canReply ? $reply : nil,
            placeholder: String(localized: "Write a reply…", bundle: .module),
            submit: canReply
                ? String(localized: "Reply", bundle: .module)
                : String(localized: "Open on GitHub", bundle: .module),
            dismiss: String(localized: "Close", bundle: .module),
            onSubmit: canReply ? send : { session.openOnGitHub(thread) },
            onDismiss: { session.closeThread() })
    }

    private func send() {
        let body = reply
        Task {
            if await session.reply(to: thread.id, body) { reply = "" }
        }
    }

}

/// A thread's comments: author, age and Markdown body, oldest first.
/// The panel's sizes by default; the diff's card passes its font for all of it.
struct ThreadComments: View {
    let thread: ReviewThread
    var font: Font?
    var authorFont: Font?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: comment.author)
                            .font(authorFont ?? .callout.weight(.semibold))
                        AgeText(date: comment.date).font(font ?? .caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(CommentText.markdown(comment.body)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum CommentText {
    /// Inline Markdown, keeping the comment's own line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
