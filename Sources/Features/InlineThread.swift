import AppKit
import DiffView
import SeamCore
import SwiftUI

/// The thread open in the diff (SPEC §7.7): its conversation, a reply box and its actions, in the
/// same amber card as the composer for a new thread.
struct InlineThread: View {
    let session: RepoSession
    let id: String
    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var placed: PlacedThread? {
        session.selected?.placedThreads.first { $0.id == id }
    }

    var body: some View {
        if let placed {
            content(placed.thread, lines: placed.placement)
        }
    }

    private func content(_ thread: ReviewThread, lines: ThreadPlacement) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(thread, lines: lines)
            ThreadComments(thread: thread)
            // Three lines whatever is typed, so the row's height doesn't change under the reader.
            TextField(
                String(localized: "Reply…", bundle: .module), text: $reply, axis: .vertical
            )
            .lineLimit(3, reservesSpace: true)
            .textFieldStyle(.roundedBorder)
            .focused($replyFocused)
            HStack(spacing: 8) {
                Text(
                    "\(SeamCommand.label(CommandCatalog.send.key, CommandCatalog.send.modifiers)) Reply   ⎋ Close",
                    bundle: .module
                )
                .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Reply", bundle: .module)) { send() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(CommandCatalog.send)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .onExitCommand { session.closeThread() }
    }

    private func header(_ thread: ReviewThread, lines: ThreadPlacement) -> some View {
        HStack(spacing: 8) {
            Image(systemName: thread.isResolved ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(
                    thread.isResolved
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color(nsColor: ThreadColor.accent)))
            Text(verbatim: Self.title(thread, lines: lines))
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(
                thread.isResolved
                    ? String(localized: "Reopen", bundle: .module)
                    : String(localized: "Resolve", bundle: .module)
            ) {
                Task { await session.setResolved(!thread.isResolved, thread: thread.id) }
            }
            .help(
                CommandCatalog.help(
                    thread.isResolved
                        ? String(localized: "Reopen", bundle: .module)
                        : String(localized: "Resolve", bundle: .module),
                    command: "resolve-thread"))
            // Quiet: Undo brings a deleted thread back.
            Button(role: .destructive) {
                Task { await session.deleteThread(thread.id) }
            } label: {
                Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Delete this thread (Undo brings it back)", bundle: .module))
            Button {
                session.closeThread()
            } label: {
                Label(String(localized: "Close", bundle: .module), systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(String(localized: "Close (⎋)", bundle: .module))
        }
        .controlSize(.small)
    }

    /// "Thread on src/a.cs, line 12 · 3 comments · resolved".
    static func title(_ thread: ReviewThread, lines placement: ThreadPlacement) -> String {
        let lines = if case .lines(let now) = placement { now } else { thread.anchor.lines }
        let range =
            lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)–\(lines.upperBound)"
        let place =
            thread.anchor.side == .old
            ? String(
                localized: "Thread on \(thread.anchor.path), old line \(range)", bundle: .module)
            : String(localized: "Thread on \(thread.anchor.path), line \(range)", bundle: .module)
        let status = thread.isResolved ? String(localized: " · resolved", bundle: .module) : ""
        return "\(place) · \(Counted.comments(thread.comments.count))\(status)"
    }

    private func send() {
        let body = reply
        Task {
            if await session.reply(to: id, body) { reply = "" }
        }
    }
}

/// Hosts `InlineThread` in the diff and measures it at a width, so its row fits it.
final class InlineThreadHost: NSView, InlineThreadView {
    private let controller: NSHostingController<InlineThread>

    init(session: RepoSession, id: String) {
        controller = NSHostingController(rootView: InlineThread(session: session, id: id))
        controller.sizingOptions = []
        super.init(frame: .zero)
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        controller.view.frame = bounds
    }

    func height(forWidth width: Double) -> Double {
        controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
