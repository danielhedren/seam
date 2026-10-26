import AppKit
import DiffView
import ReviewModel
import SwiftUI

extension SeamCommand {
    static func label(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> String {
        label(CommandKey(key.character), CommandModifiers(modifiers))
    }

    @MainActor
    func keyboardShortcut(for session: RepoSession?) -> KeyboardShortcut? {
        switch shortcut {
        case .none: nil
        case .command(let key, let modifiers):
            KeyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(modifiers))
        case .single(let key, let modifiers):
            session.map(focus.holds) == true
                ? KeyboardShortcut(KeyEquivalent(key), modifiers: EventModifiers(modifiers)) : nil
        case .commandWhen(let key, let focus):
            session.map(focus.holds) == true ? KeyboardShortcut(KeyEquivalent(key)) : nil
        }
    }
}

extension CommandCatalog {
    /// File › New Window and Open Repository, which the File menu builds itself.
    static let newWindow = KeyboardShortcut("n")
    static let openRepository = KeyboardShortcut("o")
    /// Sends what's typed in the thread panel's reply box.
    static let send = KeyboardShortcut(.return, modifiers: .command)
    /// Posts a new thread's text as a note, asking no answer.
    static let sendNote = KeyboardShortcut(.return, modifiers: [.command, .option])

    /// The keys the diff view pages on by itself, from Go › Page Down and Page Up.
    static var diffKeyBindings: [DiffKeyBinding: DiffKeyAction] {
        var bindings: [DiffKeyBinding: DiffKeyAction] = [:]
        for (id, action) in [("page-down", DiffKeyAction.pageDown), ("page-up", .pageUp)] {
            guard case .single(let key, let modifiers) = byID[id]?.shortcut else { continue }
            bindings[DiffKeyBinding(key.character, shift: modifiers.contains(.shift))] = action
        }
        return bindings
    }

    /// Whether `event` is `shortcut`, for views that handle a catalog key themselves.
    static func matches(_ event: NSEvent, _ shortcut: KeyboardShortcut) -> Bool {
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        return event.modifierFlags.intersection(.deviceIndependentFlagsMask) == flags
            && event.charactersIgnoringModifiers == String(shortcut.key.character)
    }

    static func help(_ text: String, shortcut: KeyboardShortcut) -> String {
        let key = CommandKey(shortcut.key.character)
        return "\(text) (\(SeamCommand.label(key, CommandModifiers(shortcut.modifiers))))"
    }
}

extension KeyEquivalent {
    init(_ key: CommandKey) { self.init(key.character) }
}

extension EventModifiers {
    init(_ modifiers: CommandModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.control) { insert(.control) }
    }
}

extension CommandModifiers {
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.control) { insert(.control) }
    }
}
