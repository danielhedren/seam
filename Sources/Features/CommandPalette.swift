import ReviewModel
import SeamCore
import SwiftUI

/// `⇧⌘P`: every command, plus a jump to each worktree, searched by name (SPEC §7.5).
struct CommandPalette: View {
    let session: RepoSession
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var fieldFocused: Bool

    typealias Entry = PaletteEntry

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

    private var ranked: [Entry] { session.paletteEntries(matching: query) }

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
