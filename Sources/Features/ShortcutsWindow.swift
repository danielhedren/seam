import SwiftUI

/// Help › Keyboard Shortcuts: every shortcut, by menu, read from `CommandCatalog` so the list
/// follows the menus (SPEC §9).
struct ShortcutsView: View {
    @State private var query = ""

    var body: some View {
        let groups = ShortcutSheet.groups(matching: query)
        List {
            ForEach(groups, id: \.menu) { group in
                Section(group.menu) {
                    ForEach(group.entries, id: \.id) { ShortcutRow(entry: $0) }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                Text("No matching shortcuts", bundle: .module).foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, placement: .toolbar)
        .frame(minWidth: 380, minHeight: 300)
    }
}

struct ShortcutRow: View {
    let entry: ShortcutSheet.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                if let note = entry.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(entry.shortcut).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

@MainActor
enum ShortcutSheet {
    struct Entry: Equatable {
        var id: String
        var title: String
        var shortcut: String
        var note: String?
    }

    struct Group: Equatable {
        var menu: String
        var entries: [Entry]
    }

    /// In menu-bar order; commands without a shortcut are left out.
    static var groups: [Group] {
        let file = [
            Entry(
                id: "new-window", title: String(localized: "New Window", bundle: .module),
                shortcut: label(CommandCatalog.newWindow)),
            Entry(
                id: "open-repository",
                title: String(localized: "Open Repository…", bundle: .module),
                shortcut: label(CommandCatalog.openRepository)),
        ]
        let menus: [SeamCommand.Menu] = [.file, .find, .view, .go, .review]
        return menus.map { menu in
            let commands = CommandCatalog.items(in: menu).filter { !$0.shortcutLabel.isEmpty }
                .map {
                    Entry(
                        id: $0.id, title: $0.title, shortcut: $0.shortcutLabel, note: $0.focus.note)
                }
            let name =
                menu == .find ? String(localized: "Edit › Find", bundle: .module) : menu.name
            return Group(menu: name, entries: (menu == .file ? file : []) + commands)
        }
        .filter { !$0.entries.isEmpty }
    }

    /// Entries whose title, shortcut or menu contains the query, ignoring case.
    static func groups(matching query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let menuMatches = group.menu.localizedStandardContains(query)
            let entries = group.entries.filter {
                menuMatches || $0.title.localizedStandardContains(query)
                    || $0.shortcut.localizedStandardContains(query)
            }
            return entries.isEmpty ? nil : Group(menu: group.menu, entries: entries)
        }
    }

    private static func label(_ shortcut: KeyboardShortcut) -> String {
        SeamCommand.label(shortcut.key, shortcut.modifiers)
    }
}
