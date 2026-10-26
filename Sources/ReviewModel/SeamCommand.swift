import Foundation
import SeamCore

/// One action, shared by the menu bar and the command palette so the two can't drift (SPEC §9).
package struct SeamCommand: Identifiable {
    /// `find` is Edit › Find, the submenu macOS apps keep their find commands in.
    package enum Menu {
        case file, find, view, go, review

        /// Where the palette says a command lives.
        package var name: String {
            switch self {
            case .file: String(localized: "File", bundle: .module)
            case .find: String(localized: "Find", bundle: .module)
            case .view: String(localized: "View", bundle: .module)
            case .go: String(localized: "Go", bundle: .module)
            case .review: String(localized: "Review", bundle: .module)
            }
        }
    }

    package enum Shortcut {
        case none
        /// A ⌘ shortcut, always attached.
        case command(CommandKey, CommandModifiers = .command)
        /// A bare key, attached only while the diff or file list has focus: AppKit lets a menu
        /// key equivalent win over a focused text field, even when the item is disabled.
        case single(CommandKey, CommandModifiers = [])
        /// Attached only while the condition holds: ⌘F belongs to Filter Files in the file list
        /// and to Find elsewhere, and to neither with no repo window, where both are disabled.
        case commandWhen(CommandKey, Focus)
    }

    /// Where a shortcut works, for the conditions a menu item can't show by itself.
    package enum Focus {
        case anywhere, review, fileList, outsideFileList

        @MainActor
        package func holds(in session: RepoSession) -> Bool {
            switch self {
            case .anywhere: true
            case .review: session.reviewHasFocus
            case .fileList: session.fileListHasFocus
            case .outsideFileList: !session.fileListHasFocus
            }
        }

        /// The Keyboard Shortcuts window's note; nil where the key works in the whole window.
        package var note: String? {
            switch self {
            case .anywhere: nil
            case .review: String(localized: "In the diff or file list", bundle: .module)
            case .fileList: String(localized: "In the file list", bundle: .module)
            case .outsideFileList: String(localized: "Outside the file list", bundle: .module)
            }
        }
    }

    package var focus: Focus {
        switch shortcut {
        case .none, .command: .anywhere
        case .single: .review
        case .commandWhen(_, let focus): focus
        }
    }

    package let id: String
    package let title: String
    package let menu: Menu
    /// Commands in the same section sit between the same dividers.
    package let section: Int
    package let shortcut: Shortcut
    package var isEnabled: @MainActor (RepoSession) -> Bool = { $0.selected != nil }
    /// Set for commands that show a checkmark in the menu.
    package var isOn: (@MainActor (RepoSession) -> Bool)?
    /// Set for commands whose title says what they'll do now, as the HIG prefers to a "Toggle":
    /// Hide Sidebar or Show Sidebar.
    var currentTitle: (@MainActor (RepoSession) -> String?)?
    package let run: @MainActor (RepoSession) -> Void

    @MainActor
    package func title(for session: RepoSession?) -> String {
        session.flatMap { currentTitle?($0) } ?? title
    }

    /// How the palette shows the shortcut: "⌘K", "⇧⌘G", "j".
    package var shortcutLabel: String {
        switch shortcut {
        case .none: ""
        case .command(let key, let modifiers), .single(let key, let modifiers):
            Self.label(key, modifiers)
        case .commandWhen(let key, _): Self.label(key, .command)
        }
    }

    /// The palette's label: like `shortcutLabel`, but ⌘F only on whichever of Find and Filter
    /// Files it runs now.
    @MainActor
    package func shortcutLabel(for session: RepoSession) -> String {
        if case .commandWhen(_, let focus) = shortcut, !focus.holds(in: session) { return "" }
        return shortcutLabel
    }

    package static func label(_ key: CommandKey, _ modifiers: CommandModifiers) -> String {
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        let character = key.character
        label +=
            character == " "
            ? String(localized: "Space", bundle: .module)
            : Self.symbols[key] ?? String(character).uppercased()
        return label
    }

    /// Keys without a printable character, written as the menu bar writes them.
    private static let symbols: [CommandKey: String] = [
        .return: "↩", .escape: "⎋", .delete: "⌫", .deleteForward: "⌦", .tab: "⇥",
        .upArrow: "↑", .downArrow: "↓", .leftArrow: "←", .rightArrow: "→",
        .home: "↖", .end: "↘", .pageUp: "⇞", .pageDown: "⇟",
    ]
}

/// A key as the catalog names it, without SwiftUI (ADR 0007): its character, the same one
/// SwiftUI's `KeyEquivalent` uses, so the menus map it one to one.
package struct CommandKey: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    package var character: Character

    package init(_ character: Character) { self.character = character }
    package init(extendedGraphemeClusterLiteral character: Character) { self.character = character }

    package static let space = CommandKey(" ")
    package static let `return` = CommandKey("\r")
    package static let escape = CommandKey("\u{1B}")
    package static let delete = CommandKey("\u{08}")
    package static let deleteForward = CommandKey("\u{F728}")
    package static let tab = CommandKey("\t")
    package static let upArrow = CommandKey("\u{F700}")
    package static let downArrow = CommandKey("\u{F701}")
    package static let leftArrow = CommandKey("\u{F702}")
    package static let rightArrow = CommandKey("\u{F703}")
    package static let home = CommandKey("\u{F729}")
    package static let end = CommandKey("\u{F72B}")
    package static let pageUp = CommandKey("\u{F72C}")
    package static let pageDown = CommandKey("\u{F72D}")
}

package struct CommandModifiers: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let command = CommandModifiers(rawValue: 1)
    package static let shift = CommandModifiers(rawValue: 2)
    package static let option = CommandModifiers(rawValue: 4)
    package static let control = CommandModifiers(rawValue: 8)
}
