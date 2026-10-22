import SeamCore
import SwiftUI

/// `⇧⌘P`: every command, plus a jump to each worktree, searched by name (SPEC §7.5).
struct CommandPalette: View {
    let session: RepoSession
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var fieldFocused: Bool

    private struct Entry: Identifiable {
        var id: String
        var title: String
        var shortcut: String
        var run: @MainActor () -> Void
    }

    var body: some View {
        let entries = ranked
        VStack(spacing: 0) {
            TextField(String(localized: "Run a command", bundle: .module), text: $query)
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
                HStack {
                    Text(entry.title)
                    Spacer()
                    Text(entry.shortcut).foregroundStyle(.secondary).monospaced()
                }
                .contentShape(Rectangle())
                .onTapGesture { run(entry) }
                .tag(entry.id)
            }
            .frame(height: 320)
        }
        .frame(width: 520)
        .onAppear { fieldFocused = true }
        .onExitCommand { session.showsPalette = false }
        .onChange(of: query) { selection = ranked.first?.id }
    }

    private var entries: [Entry] {
        let commands = CommandCatalog.all.filter { $0.isEnabled(session) }.map { command in
            Entry(
                id: command.id, title: command.title(for: session), shortcut: command.shortcutLabel
            ) {
                command.run(session)
            }
        }
        let worktrees = session.sortedReviews.map { review in
            Entry(
                id: "go:" + review.id,
                title: String(localized: "Go to \(review.worktree.name)", bundle: .module),
                shortcut: ""
            ) { session.select(review.id) }
        }
        return commands + worktrees
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
