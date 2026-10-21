import SwiftUI
import Testing

@testable import Features

@MainActor @Suite struct CommandCatalogTests {
    private func key(_ shortcut: SeamCommand.Shortcut) -> String? {
        switch shortcut {
        case .command(let key, let modifiers), .single(let key, let modifiers):
            "\(key.character)-\(modifiers.rawValue)"
        case .commandUnless(let key, _): "\(key.character)-\(EventModifiers.command.rawValue)"
        case .none: nil
        }
    }

    @Test func idsAreUnique() {
        let ids = CommandCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func onlyFindAndFilterShareAShortcutAndTheyTakeTurns() {
        var seen: [String: [String]] = [:]
        for command in CommandCatalog.all {
            if let key = key(command.shortcut) { seen[key, default: []].append(command.id) }
        }
        let shared = seen.values.filter { $0.count > 1 }
        #expect(shared.map { Set($0) } == [["find", "filter-files"]])
    }

    @Test func bareKeysHaveNoCommandModifier() {
        for command in CommandCatalog.all {
            if case .single(_, let modifiers) = command.shortcut {
                #expect(!modifiers.contains(.command), "\(command.id)")
            }
        }
    }

    @Test func shortcutLabelsUseMacSymbols() throws {
        func label(_ id: String) throws -> String {
            try #require(CommandCatalog.all.first { $0.id == id }).shortcutLabel
        }
        #expect(try label("switcher") == "⌘K")
        #expect(try label("find-previous") == "⇧⌘G")
        #expect(try label("next-file") == "j")
        #expect(try label("page-up") == "⇧Space")
        #expect(try label("detected-base") == "")
    }
}
