import AppKit
import DiffView
import SeamCore
import SwiftUI

/// The diff's one card (SPEC §7.7), for writing a new thread and for reading and answering one:
/// the same view either way, so the two can't look different. In the diff's font, on the amber
/// frame the canvas draws: a title, the thread's actions and comments if it has any, a text box
/// without a background of its own, and the keys as hints at the bottom, which are also buttons.
struct ThreadCardView: View {
    let session: RepoSession
    let card: DiffCard
    @State private var reply = ""

    var body: some View {
        switch card {
        case .draft(let marker):
            layout(
                title: Self.draftTitle(marker), thread: nil,
                text: Binding(
                    get: { session.draft?.body ?? "" }, set: { session.draft?.body = $0 }),
                placeholder: String(localized: "Write a comment…", bundle: .module),
                submit: String(localized: "Comment", bundle: .module),
                dismiss: String(localized: "Cancel", bundle: .module),
                onSubmit: { Task { await session.submitDraft() } },
                onDismiss: { session.draft = nil })
        case .thread(let id):
            if let placed = session.selected?.placedThreads.first(where: { $0.id == id }) {
                layout(
                    title: Self.threadTitle(placed.thread, lines: placed.placement),
                    thread: placed.thread, text: $reply,
                    placeholder: String(localized: "Write a reply…", bundle: .module),
                    submit: String(localized: "Reply", bundle: .module),
                    dismiss: String(localized: "Close", bundle: .module),
                    onSubmit: { send(to: id) }, onDismiss: { session.closeThread() })
            }
        }
    }

    private func layout(
        title: String, thread: ReviewThread?, text: Binding<String>, placeholder: String,
        submit: String, dismiss: String, onSubmit: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) -> some View {
        let diffFont = session.settings.font
        // A weight on a font made from an NSFont is ignored, so the bold face is asked for.
        let bold = Font(NSFontManager.shared.convert(diffFont, toHaveTrait: .boldFontMask))
        let isEmpty = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text(verbatim: title).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let thread { actions(thread) }
            }
            if let thread { ThreadComments(thread: thread, font: Font(diffFont), authorFont: bold) }
            // Four lines whatever is typed, so the card doesn't grow under the reader.
            CardTextBox(
                text: text, placeholder: placeholder, font: diffFont, lines: 4,
                takesFocus: thread == nil, onSubmit: onSubmit, onCancel: onDismiss)
            HStack(spacing: 24) {
                Spacer()
                Button(action: onSubmit) {
                    Text(
                        verbatim:
                            "\(SeamCommand.label(CommandCatalog.send.key, CommandCatalog.send.modifiers)) \(submit)"
                    )
                }
                .disabled(isEmpty)
                Button(action: onDismiss) { Text(verbatim: "⎋ \(dismiss)") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerStyle(.link)
        }
        .font(Font(diffFont))
        .padding(.horizontal, 7)
        .onExitCommand(perform: onDismiss)
    }

    private func actions(_ thread: ReviewThread) -> some View {
        let resolve =
            thread.isResolved
            ? String(localized: "Reopen", bundle: .module)
            : String(localized: "Resolve", bundle: .module)
        return HStack(spacing: 16) {
            Button(resolve) {
                Task { await session.setResolved(!thread.isResolved, thread: thread.id) }
            }
            .help(CommandCatalog.help(resolve, command: "resolve-thread"))
            // Quiet: Undo brings a deleted thread back.
            Button(role: .destructive) {
                Task { await session.deleteThread(thread.id) }
            } label: {
                Label(String(localized: "Delete", bundle: .module), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .help(String(localized: "Delete this thread (Undo brings it back)", bundle: .module))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointerStyle(.link)
    }

    private func send(to id: String) {
        let body = reply
        Task {
            if await session.reply(to: id, body) { reply = "" }
        }
    }

    private static func range(_ lines: ClosedRange<Int>) -> String {
        lines.count == 1 ? "\(lines.lowerBound)" : "\(lines.lowerBound)–\(lines.upperBound)"
    }

    /// "New thread on src/a.cs, line 12".
    static func draftTitle(_ marker: DraftMarker) -> String {
        let lines = range(marker.lines)
        return marker.side == .old
            ? String(localized: "New thread on \(marker.path), old line \(lines)", bundle: .module)
            : String(localized: "New thread on \(marker.path), line \(lines)", bundle: .module)
    }

    /// "Thread on src/a.cs, line 12 · 3 comments · resolved".
    static func threadTitle(_ thread: ReviewThread, lines placement: ThreadPlacement) -> String {
        let lines = range(
            { if case .lines(let now) = placement { now } else { thread.anchor.lines } }())
        let place =
            thread.anchor.side == .old
            ? String(
                localized: "Thread on \(thread.anchor.path), old line \(lines)", bundle: .module)
            : String(localized: "Thread on \(thread.anchor.path), line \(lines)", bundle: .module)
        let status = thread.isResolved ? String(localized: " · resolved", bundle: .module) : ""
        return "\(place) · \(Counted.comments(thread.comments.count))\(status)"
    }
}

/// Hosts the card in the diff and measures it at a width, so its row fits it. The model changes
/// before SwiftUI redraws the card, so the host watches what the card shows and asks to be
/// measured again on the next turn, once the change has landed.
final class ThreadCardHost: NSView, DiffCardView {
    private let controller: NSHostingController<ThreadCardView>
    private let session: RepoSession
    private let card: DiffCard
    var onHeightChange: (() -> Void)?

    init(session: RepoSession, card: DiffCard) {
        controller = NSHostingController(rootView: ThreadCardView(session: session, card: card))
        controller.sizingOptions = []
        self.session = session
        self.card = card
        super.init(frame: .zero)
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.autoresizingMask = [.width, .height]
        addSubview(controller.view)
        watch()
    }

    required init?(coder: NSCoder) { nil }

    private func watch() {
        withObservationTracking {
            if case .thread(let id) = card {
                _ = session.selected?.placedThreads.first { $0.id == id }
            }
            _ = session.settings.font
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.onHeightChange?()
                self.watch()
            }
        }
    }

    override func layout() {
        super.layout()
        controller.view.frame = bounds
    }

    func height(forWidth width: Double) -> Double {
        controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }
}
