import SeamCore
import SwiftUI

/// Every action in the menu bar (SPEC §9). Single-letter shortcuts attach only while the diff or
/// file list has focus: AppKit lets a menu key equivalent win over a focused text field, even when
/// the item is disabled, so a bare letter must not be registered at all while typing.
public struct SeamCommands: Commands {
    @FocusedValue(\.repoSession) private var session
    @FocusedValue(\.columnVisibility) private var columns
    private let openRepository: () -> Void

    public init(openRepository: @escaping () -> Void) {
        self.openRepository = openRepository
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Open Repository…", bundle: .module), action: openRepository)
                .keyboardShortcut("o")
        }
        CommandGroup(after: .textEditing) {
            Button(String(localized: "Filter Files", bundle: .module)) {
                session?.filterFocusRequests += 1
            }
            .keyboardShortcut("f")
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
