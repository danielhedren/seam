import SeamCore
import SwiftUI

/// One action, shared by the menu bar and the command palette so the two can't drift (SPEC §9).
struct SeamCommand: Identifiable {
    enum Menu { case edit, view, go, review }

    enum Shortcut {
        case none
        /// A ⌘ shortcut, always attached.
        case command(KeyEquivalent, EventModifiers = .command)
        /// A bare key, attached only while the diff or file list has focus: AppKit lets a menu
        /// key equivalent win over a focused text field, even when the item is disabled.
        case single(KeyEquivalent, EventModifiers = [])
        /// Attached only while the condition holds: ⌘F belongs to Filter Files in the file list
        /// and to Find elsewhere, and to neither with no repo window, where both are disabled.
        case commandWhen(KeyEquivalent, @MainActor (RepoSession) -> Bool)
    }

    let id: String
    let title: String
    let menu: Menu
    /// Commands in the same section sit between the same dividers.
    let section: Int
    let shortcut: Shortcut
    var isEnabled: @MainActor (RepoSession) -> Bool = { $0.selected != nil }
    /// Set for commands that show a checkmark in the menu.
    var isOn: (@MainActor (RepoSession) -> Bool)?
    let run: @MainActor (RepoSession) -> Void

    @MainActor
    func keyboardShortcut(for session: RepoSession?) -> KeyboardShortcut? {
        switch shortcut {
        case .none: nil
        case .command(let key, let modifiers): KeyboardShortcut(key, modifiers: modifiers)
        case .single(let key, let modifiers):
            session?.reviewHasFocus == true ? KeyboardShortcut(key, modifiers: modifiers) : nil
        case .commandWhen(let key, let condition):
            session.map(condition) == true ? KeyboardShortcut(key) : nil
        }
    }

    /// How the palette shows the shortcut: "⌘K", "⇧⌘G", "j".
    var shortcutLabel: String {
        let (key, modifiers): (KeyEquivalent, EventModifiers) =
            switch shortcut {
            case .none: (KeyEquivalent(" "), [])
            case .command(let key, let modifiers), .single(let key, let modifiers):
                (key, modifiers)
            case .commandWhen(let key, _): (key, .command)
            }
        if case .none = shortcut { return "" }
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        let character = key.character
        label +=
            character == " "
            ? String(localized: "Space", bundle: .module)
            : modifiers.isEmpty ? String(character) : String(character).uppercased()
        return label
    }
}

@MainActor
enum CommandCatalog {
    private static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    static let all: [SeamCommand] = edit + view + go + review

    static let edit: [SeamCommand] = [
        SeamCommand(
            id: "find", title: localized("Find…"), menu: .edit, section: 0,
            shortcut: .commandWhen("f", { !$0.fileListHasFocus }), run: { $0.showFind() }),
        SeamCommand(
            id: "find-next", title: localized("Find Next"), menu: .edit, section: 0,
            shortcut: .command("g"), isEnabled: { $0.findResult.total > 0 },
            run: { $0.diff.moveToMatch(by: 1) }),
        SeamCommand(
            id: "find-previous", title: localized("Find Previous"), menu: .edit, section: 0,
            shortcut: .command("g", [.command, .shift]), isEnabled: { $0.findResult.total > 0 },
            run: { $0.diff.moveToMatch(by: -1) }),
        SeamCommand(
            id: "filter-files", title: localized("Filter Files"), menu: .edit, section: 0,
            shortcut: .commandWhen("f", { $0.fileListHasFocus }),
            run: { $0.filterFocusRequests += 1 }),
    ]

    static let view: [SeamCommand] = [
        SeamCommand(
            id: "toggle-sidebars", title: localized("Toggle Sidebars"), menu: .view, section: 0,
            shortcut: .command("\\"), isEnabled: { _ in true },
            run: { $0.columns = $0.columns == .diffOnly ? .all : .diffOnly }),
        SeamCommand(
            id: "toggle-worktrees", title: localized("Toggle Worktree List"), menu: .view,
            section: 0, shortcut: .command("\\", [.command, .option]), isEnabled: { _ in true },
            run: { $0.columns = $0.columns == .filesAndDiff ? .all : .filesAndDiff }),
        SeamCommand(
            id: "bigger", title: localized("Make Text Bigger"), menu: .view, section: 1,
            shortcut: .command("="), isEnabled: { _ in true },
            run: { $0.settings.adjustFontSize(by: 1) }),
        SeamCommand(
            id: "smaller", title: localized("Make Text Smaller"), menu: .view, section: 1,
            shortcut: .command("-"), isEnabled: { _ in true },
            run: { $0.settings.adjustFontSize(by: -1) }),
        SeamCommand(
            id: "actual-size", title: localized("Actual Size"), menu: .view, section: 1,
            shortcut: .command("0"), isEnabled: { _ in true }, run: { $0.settings.fontSize = 12 }),
        SeamCommand(
            id: "side-by-side", title: localized("Side by Side"), menu: .view, section: 2,
            shortcut: .single("s"), isOn: { $0.selected?.mode == .split },
            run: { $0.toggleMode() }),
        SeamCommand(
            id: "wrap", title: localized("Wrap Lines"), menu: .view, section: 2,
            shortcut: .single("w"), isOn: { $0.selected?.wraps == true },
            run: { $0.toggleWrap() }),
        SeamCommand(
            id: "flat-files", title: localized("Files as Flat List"), menu: .view, section: 2,
            shortcut: .none, isOn: { $0.selected?.flatFileList == true },
            run: { $0.selected?.flatFileList.toggle() }),
        SeamCommand(
            id: "sort-recent", title: localized("Sort Worktrees by Recent Change"), menu: .view,
            section: 3, shortcut: .none, isEnabled: { _ in true }, isOn: { $0.sort == .recent },
            run: { $0.sort = .recent }),
        SeamCommand(
            id: "sort-name", title: localized("Sort Worktrees by Name"), menu: .view, section: 3,
            shortcut: .none, isEnabled: { _ in true }, isOn: { $0.sort == .name },
            run: { $0.sort = .name }),
        SeamCommand(
            id: "hide-missing", title: localized("Hide Missing Worktrees"), menu: .view,
            section: 3, shortcut: .none, isEnabled: { _ in true }, isOn: { $0.hidesMissing },
            run: { $0.hidesMissing.toggle() }),
    ]

    static let go: [SeamCommand] =
        [
            SeamCommand(
                id: "switcher", title: localized("Switch Worktree…"), menu: .go, section: 0,
                shortcut: .command("k"), isEnabled: { _ in true },
                run: { $0.showsSwitcher = true }),
            SeamCommand(
                id: "palette", title: localized("Command Palette…"), menu: .go, section: 0,
                shortcut: .command("p", [.command, .shift]), isEnabled: { _ in true },
                run: { $0.showsPalette = true }),
            SeamCommand(
                id: "previous-worktree", title: localized("Previous Worktree"), menu: .go,
                section: 0, shortcut: .command("["), isEnabled: { _ in true },
                run: { $0.selectAdjacent(-1) }),
            SeamCommand(
                id: "next-worktree", title: localized("Next Worktree"), menu: .go, section: 0,
                shortcut: .command("]"), isEnabled: { _ in true }, run: { $0.selectAdjacent(1) }),
        ]
        + (1..<10).map { position in
            SeamCommand(
                id: "worktree-\(position)", title: localized("Worktree \(position)"), menu: .go,
                section: 1, shortcut: .command(KeyEquivalent(Character(String(position)))),
                isEnabled: { $0.reviews.count >= position },
                run: { $0.select(position: position - 1) })
        }
        + [
            SeamCommand(
                id: "next-file", title: localized("Next File"), menu: .go, section: 2,
                shortcut: .single("j"), run: { $0.diff.moveFile(by: 1) }),
            SeamCommand(
                id: "previous-file", title: localized("Previous File"), menu: .go, section: 2,
                shortcut: .single("k"), run: { $0.diff.moveFile(by: -1) }),
            SeamCommand(
                id: "next-hunk", title: localized("Next Hunk"), menu: .go, section: 2,
                shortcut: .single("n"), run: { $0.diff.moveHunk(by: 1) }),
            SeamCommand(
                id: "previous-hunk", title: localized("Previous Hunk"), menu: .go, section: 2,
                shortcut: .single("p"), run: { $0.diff.moveHunk(by: -1) }),
            SeamCommand(
                id: "page-down", title: localized("Page Down"), menu: .go, section: 2,
                shortcut: .single(.space), run: { $0.diff.page(by: 1) }),
            SeamCommand(
                id: "page-up", title: localized("Page Up"), menu: .go, section: 2,
                shortcut: .single(.space, .shift), run: { $0.diff.page(by: -1) }),
        ]

    static let review: [SeamCommand] = [
        SeamCommand(
            id: "scope-all", title: localized("All Changes"), menu: .review, section: 0,
            shortcut: .single("1"), isOn: { $0.selected?.isShowing(.all) == true },
            run: { $0.setScope(.all) }),
        SeamCommand(
            id: "scope-committed", title: localized("Committed"), menu: .review, section: 0,
            shortcut: .single("2"), isOn: { $0.selected?.isShowing(.committed) == true },
            run: { $0.setScope(.committed) }),
        SeamCommand(
            id: "scope-uncommitted", title: localized("Uncommitted"), menu: .review, section: 0,
            shortcut: .single("3"), isOn: { $0.selected?.isShowing(.uncommitted) == true },
            run: { $0.setScope(.uncommitted) }),
        SeamCommand(
            id: "latest-commit", title: localized("Latest Commit Only"), menu: .review,
            section: 0, shortcut: .single("4"),
            isEnabled: { $0.selected?.commitLog?.commits.isEmpty == false },
            isOn: { $0.selected?.isShowingLatestCommit == true },
            run: { $0.selectLatestCommit() }),
        SeamCommand(
            id: "whitespace", title: localized("Hide Whitespace Changes"), menu: .review,
            section: 0, shortcut: .none, isOn: { $0.selected?.effectiveWhitespace != .show },
            run: { $0.toggleWhitespace() }),
        SeamCommand(
            id: "viewed", title: localized("Mark as Viewed"), menu: .review, section: 1,
            shortcut: .single("v"), run: { $0.toggleViewed() }),
        SeamCommand(
            id: "editor", title: localized("Open in Editor"), menu: .review, section: 1,
            shortcut: .single("o"), run: { $0.openInEditor() }),
        SeamCommand(
            id: "copy-path", title: localized("Copy Path"), menu: .review, section: 1,
            shortcut: .command("c", [.command, .option]),
            isEnabled: { $0.selected?.currentFile != nil },
            run: { session in
                session.selected?.currentFile.map { session.copyPath($0, relative: false) }
            }),
        SeamCommand(
            id: "copy-relative-path", title: localized("Copy Relative Path"), menu: .review,
            section: 1, shortcut: .command("c", [.command, .option, .shift]),
            isEnabled: { $0.selected?.currentFile != nil },
            run: { session in
                session.selected?.currentFile.map { session.copyPath($0, relative: true) }
            }),
        SeamCommand(
            id: "reveal", title: localized("Reveal in Finder"), menu: .review, section: 1,
            shortcut: .command("r", [.command, .shift]),
            isEnabled: { $0.selected?.currentFile != nil },
            run: { session in session.selected?.currentFile.map(session.revealInFinder) }),
        SeamCommand(
            id: "collapse", title: localized("Collapse or Expand File"), menu: .review,
            section: 1, shortcut: .single("x"), run: { $0.toggleCollapsed() }),
        SeamCommand(
            id: "base", title: localized("Choose Base…"), menu: .review, section: 2,
            shortcut: .single("b"), run: { $0.showsBasePicker.toggle() }),
        SeamCommand(
            id: "keep-parent", title: localized("Keep Parent That Looks Merged"), menu: .review,
            section: 2, shortcut: .none, isEnabled: { $0.selected?.staleParent != nil },
            run: { $0.dismissStaleParent() }),
        SeamCommand(
            id: "detected-base", title: localized("Use Detected Base"), menu: .review,
            section: 2, shortcut: .none, isEnabled: { $0.selected?.baseOverride != nil },
            run: { $0.setBaseOverride(nil) }),
        SeamCommand(
            id: "reload", title: localized("Reload"), menu: .review, section: 3,
            shortcut: .single("r"), run: { $0.reload() }),
        SeamCommand(
            id: "fetch", title: localized("Fetch"), menu: .review, section: 3,
            shortcut: .single("f"), isEnabled: { $0.repository != nil && !$0.isFetching },
            run: { $0.fetch() }),
    ]

    static func items(in menu: SeamCommand.Menu) -> [SeamCommand] {
        all.filter { $0.menu == menu }
    }
}
