import SeamCore
import SwiftUI

/// Every action in the menu bar (SPEC §9). Single-letter shortcuts attach only while the diff or
/// file list has focus: AppKit lets a menu key equivalent win over a focused text field, even when
/// the item is disabled, so a bare letter must not be registered at all while typing.
struct SeamCommands: Commands {
    @FocusedValue(\.repoSession) private var session
    @FocusedValue(\.columnVisibility) private var columns
    private let openRepository: () -> Void

    init(openRepository: @escaping () -> Void) {
        self.openRepository = openRepository
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Open Repository…", bundle: .module), action: openRepository)
                .keyboardShortcut("o")
        }
        CommandGroup(after: .textEditing) {
            // ⌘F only while the file list has focus; in the diff it stays free for Find (§8.5).
            Button(String(localized: "Filter Files", bundle: .module)) {
                session?.filterFocusRequests += 1
            }
            .keyboardShortcut(session?.fileListHasFocus == true ? KeyboardShortcut("f") : nil)
            .disabled(session?.selected == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(String(localized: "Toggle Sidebars", bundle: .module)) {
                columns?.wrappedValue = columns?.wrappedValue == .detailOnly ? .all : .detailOnly
            }
            .keyboardShortcut("\\")
            Button(String(localized: "Toggle Worktree List", bundle: .module)) {
                columns?.wrappedValue =
                    columns?.wrappedValue == .doubleColumn ? .all : .doubleColumn
            }
            .keyboardShortcut("\\", modifiers: [.command, .option])
            Divider()
            item("Side by Side", key: "s") { $0.toggleMode() }
            if let session {
                Toggle(
                    String(localized: "Files as Flat List", bundle: .module),
                    isOn: Binding(
                        get: { session.selected?.flatFileList ?? false },
                        set: { session.selected?.flatFileList = $0 })
                )
                .disabled(session.selected == nil)
                Picker(
                    String(localized: "Sort Worktrees By", bundle: .module),
                    selection: Bindable(session).sort
                ) {
                    Text("Recently Changed", bundle: .module).tag(WorktreeSort.recent)
                    Text("Name", bundle: .module).tag(WorktreeSort.name)
                }
                Toggle(
                    String(localized: "Hide Missing Worktrees", bundle: .module),
                    isOn: Bindable(session).hidesMissing)
            }
        }
        CommandMenu(String(localized: "Go", bundle: .module)) {
            Button(String(localized: "Switch Worktree…", bundle: .module)) {
                session?.showsSwitcher = true
            }
            .keyboardShortcut("k")
            .disabled(session == nil)
            Button(String(localized: "Previous Worktree", bundle: .module)) {
                session?.selectAdjacent(-1)
            }
            .keyboardShortcut("[")
            .disabled(session == nil)
            Button(String(localized: "Next Worktree", bundle: .module)) {
                session?.selectAdjacent(1)
            }
            .keyboardShortcut("]")
            .disabled(session == nil)
            Divider()
            ForEach(1..<10) { position in
                Button(String(localized: "Worktree \(position)", bundle: .module)) {
                    session?.select(position: position - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(position))))
                .disabled((session?.sortedReviews.count ?? 0) < position)
            }
            Divider()
            item("Next File", key: "j") { $0.diff.moveFile(by: 1) }
            item("Previous File", key: "k") { $0.diff.moveFile(by: -1) }
            item("Next Hunk", key: "n") { $0.diff.moveHunk(by: 1) }
            item("Previous Hunk", key: "p") { $0.diff.moveHunk(by: -1) }
            item("Page Down", key: .space) { $0.diff.page(by: 1) }
            item("Page Up", key: .space, modifiers: .shift) { $0.diff.page(by: -1) }
        }
        CommandMenu(String(localized: "Review", bundle: .module)) {
            item("All Changes", key: "1") { $0.setScope(.all) }
            item("Committed", key: "2") { $0.setScope(.committed) }
            item("Uncommitted", key: "3") { $0.setScope(.uncommitted) }
            Divider()
            item("Collapse or Expand File", key: "x") { $0.toggleCollapsed() }
            item("Choose Base…", key: "b") { $0.showsBasePicker.toggle() }
            Button(String(localized: "Use Detected Base", bundle: .module)) {
                session?.setBaseOverride(nil)
            }
            .disabled(session?.selected?.baseOverride == nil)
            item("Reload", key: "r") { $0.reload() }
        }
    }

    private func item(
        _ title: String.LocalizationValue, key: KeyEquivalent, modifiers: EventModifiers = [],
        action: @escaping (RepoSession) -> Void
    ) -> some View {
        Button(String(localized: title, bundle: .module)) {
            if let session { action(session) }
        }
        .keyboardShortcut(
            session?.reviewHasFocus == true ? KeyboardShortcut(key, modifiers: modifiers) : nil
        )
        .disabled(session?.selected == nil)
    }
}
