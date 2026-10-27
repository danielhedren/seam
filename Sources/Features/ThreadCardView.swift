import AppKit
import DiffModel
import DiffView
import ReviewModel
import SeamCore
import SwiftUI

/// The diff's one card (SPEC §7.7), for writing a new thread and for reading and answering one:
/// the same layout either way, and as the panel's, so they can't look different. In the diff's
/// font, on the amber frame the canvas draws.
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
                onSubmitNote: { Task { await session.submitDraft(asNote: true) } },
                onDismiss: { session.draft = nil })
        case .thread(let id):
            if let placed = session.selected?.placedThreads.first(where: { $0.id == id }),
                !placed.thread.capabilities.contains(.reply)
            {
                // Read-only (SPEC §7.9): no reply box, and the one action is GitHub's page.
                layout(
                    title: placed.thread.cardTitle(placement: placed.placement),
                    thread: placed.thread, text: nil, placeholder: "",
                    submit: String(localized: "Open on GitHub", bundle: .module),
                    dismiss: String(localized: "Close", bundle: .module),
                    onSubmit: { session.openOnGitHub(placed.thread) },
                    onDismiss: { session.closeThread() }, onTitle: { session.closeThread() })
            } else if let placed = session.selected?.placedThreads.first(where: { $0.id == id }) {
                layout(
                    title: placed.thread.cardTitle(placement: placed.placement),
                    thread: placed.thread, text: $reply,
                    placeholder: String(localized: "Write a reply…", bundle: .module),
                    submit: String(localized: "Reply", bundle: .module),
                    dismiss: String(localized: "Close", bundle: .module),
                    onSubmit: { send(to: id) }, onDismiss: { session.closeThread() },
                    onTitle: { session.closeThread() })
            }
        }
    }

    private func layout(
        title: String, thread: ReviewThread?, text: Binding<String>?, placeholder: String,
        submit: String, dismiss: String, onSubmit: @escaping () -> Void,
        onSubmitNote: (() -> Void)? = nil, onDismiss: @escaping () -> Void,
        onTitle: (() -> Void)? = nil
    ) -> some View {
        ThreadCardLayout(
            session: session, font: session.settings.font, title: title, thread: thread,
            text: text, placeholder: placeholder, submit: submit, dismiss: dismiss,
            takesFocus: thread == nil, onSubmit: onSubmit, onSubmitNote: onSubmitNote,
            onDismiss: onDismiss, onTitle: onTitle
        )
        .padding(.horizontal, 7)
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

    /// "New thread on line 12"; the sticky header above names the file.
    static func draftTitle(_ marker: DraftMarker) -> String {
        let lines = range(marker.lines)
        return marker.side == .old
            ? String(localized: "New thread on old line \(lines)", bundle: .module)
            : String(localized: "New thread on line \(lines)", bundle: .module)
    }
}

/// A thread laid out the one way, in the diff's card and in the panel (SPEC §7.7): a title with
/// the thread's actions at the right, its comments, a text box without a background of its own,
/// and the keys as hints at the bottom, which are also buttons. Only the font differs.
struct ThreadCardLayout: View {
    let session: RepoSession
    let font: NSFont
    /// Nil in the panel, where the thread's summary row above says it and has the actions.
    var title: String?
    let thread: ReviewThread?
    /// The panel quotes the lines; the diff's card sits under them.
    var showsQuote = false
    let text: Binding<String>?
    let placeholder: String
    let submit: String
    let dismiss: String
    var takesFocus = false
    let onSubmit: () -> Void
    var onSubmitNote: (() -> Void)?
    let onDismiss: () -> Void
    /// Clicking an open thread's title collapses it, as clicking a collapsed one's opens it.
    var onTitle: (() -> Void)?

    var body: some View {
        // A weight on a font made from an NSFont is ignored, so the bold face is asked for.
        let bold = Font(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask))
        let isEmpty =
            text?.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 16) {
                    if let onTitle {
                        Button(action: onTitle) { titleLabel(title) }
                            .buttonStyle(.plain).pointerStyle(.link)
                    } else {
                        titleLabel(title)
                    }
                    Spacer(minLength: 4)
                    if let thread { ThreadActions(session: session, thread: thread) }
                }
            }
            if showsQuote, let thread, !thread.anchor.text.isEmpty {
                QuotedLines(anchor: thread.anchor)
            }
            if let thread { ThreadComments(thread: thread, font: Font(font), authorFont: bold) }
            if let text {
                // Four lines whatever is typed, so the card doesn't grow under the reader.
                CardTextBox(
                    text: text, placeholder: placeholder, font: font, lines: 4,
                    takesFocus: takesFocus, onSubmit: onSubmit, onCancel: onDismiss,
                    onSubmitNote: onSubmitNote)
            }
            HStack(spacing: 24) {
                Spacer()
                Button(action: onSubmit) {
                    Text(
                        verbatim: text == nil
                            ? submit
                            : "\(SeamCommand.label(CommandCatalog.send.key, CommandCatalog.send.modifiers)) \(submit)"
                    )
                }
                .disabled(isEmpty)
                if let onSubmitNote {
                    // A note asks no answer: something to know, the reader's or for an agent.
                    Button(action: onSubmitNote) {
                        Text(
                            verbatim:
                                "\(SeamCommand.label(CommandCatalog.sendNote.key, CommandCatalog.sendNote.modifiers)) \(String(localized: "Note", bundle: .module))"
                        )
                    }
                    .disabled(isEmpty)
                }
                Button(action: onDismiss) { Text(verbatim: "⎋ \(dismiss)") }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerStyle(.link)
        }
        .font(Font(font))
        .onExitCommand(perform: onDismiss)
    }

    private func titleLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            if thread?.source == .gitHub {
                Octicon.mark.image.resizable().frame(width: 13, height: 13)
                    .foregroundStyle(Color(nsColor: ThreadColor.gitHubAccent))
            }
            Text(verbatim: title).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Resolve and Delete, at the top right of a thread wherever it's laid out.
struct ThreadActions: View {
    let session: RepoSession
    let thread: ReviewThread

    var body: some View {
        if thread.capabilities.contains(.resolve) {
            let resolve =
                thread.isResolved
                ? String(localized: "Reopen", bundle: .module)
                : String(localized: "Resolve", bundle: .module)
            HStack(spacing: 16) {
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
                .help(
                    String(localized: "Delete this thread (Undo brings it back)", bundle: .module))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerStyle(.link)
        }
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
