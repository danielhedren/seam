import ReviewModel
import SeamCore
import SwiftUI

/// `⇧⌘P`: every command, plus a jump to each worktree, searched by name (SPEC §7.5).
struct CommandPalette: View {
    let session: RepoSession
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var fieldFocused: Bool

    struct Entry: Identifiable {
        var id: String
        var title: String
        /// The menu the command is in, so the reader learns where to find it next time.
        var menu: String
        var shortcut: String
        var isOn = false
        var run: @MainActor () -> Void
    }

    var body: some View {
        let entries = ranked
        VStack(spacing: 0) {
            TextField(
                String(localized: "Search commands and worktrees", bundle: .module), text: $query
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(12)
            .focused($fieldFocused)
            .onSubmit { run(entries.first { $0.id == selection } ?? entries.first) }
            .onKeyPress(.downArrow) {
                move(1, in: entries)
                return .handled
            }
            .onKeyPress(.upArrow) {
                move(-1, in: entries)
                return .handled
            }
            Divider()
            List(entries, selection: $selection) { entry in
                row(entry)
                    .contentShape(Rectangle())
                    .onTapGesture { run(entry) }
                    .tag(entry.id)
            }
            .overlay {
                if entries.isEmpty {
                    Text("No matching commands", bundle: .module).foregroundStyle(.secondary)
                }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .onAppear {
            fieldFocused = true
            selection = entries.first?.id
        }
        .onExitCommand { session.showsPalette = false }
        .onChange(of: query) { selection = ranked.first?.id }
    }

    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.caption.bold()).opacity(entry.isOn ? 1 : 0)
            Text(entry.title)
            Text(entry.menu).foregroundStyle(.tertiary)
            Spacer()
            Text(entry.shortcut).foregroundStyle(.secondary)
        }
    }

    /// The menu's commands that apply now, then a jump to each worktree, which takes the place of
    /// Go › Worktree 1…9.
    private var entries: [Entry] {
        Self.entries(for: session)
    }

    static func entries(for session: RepoSession) -> [Entry] {
        let commands = CommandCatalog.all.filter {
            !$0.id.hasPrefix("worktree-") && $0.isEnabled(session)
        }
        .map { command in
            Entry(
                id: command.id, title: command.title(for: session), menu: command.menu.name,
                shortcut: command.shortcutLabel(for: session), isOn: command.isOn?(session) ?? false
            ) { command.run(session) }
        }
        let worktrees = session.sortedReviews.enumerated().map { position, review in
            Entry(
                id: "go:" + review.id,
                title: String(localized: "Go to \(review.worktree.name)", bundle: .module),
                menu: SeamCommand.Menu.go.name,
                shortcut: position < 9 ? SeamCommand.label(Self.digit(position + 1), .command) : ""
            ) { session.select(review.id) }
        }
        return commands + worktrees
    }

    private static func digit(_ value: Int) -> KeyEquivalent {
        KeyEquivalent(Character(String(value)))
    }

    private var ranked: [Entry] {
        guard !query.isEmpty else { return entries }
        return entries.compactMap { entry in
            FuzzyMatch.score(query, in: entry.title).map { (entry, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private func move(_ delta: Int, in entries: [Entry]) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selection } ?? -1
        selection = entries[min(max(current + delta, 0), entries.count - 1)].id
    }

    private func run(_ entry: Entry?) {
        guard let entry else { return }
        session.showsPalette = false
        entry.run()
    }
}
