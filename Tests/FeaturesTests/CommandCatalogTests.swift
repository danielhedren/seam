import AppKit
import DiffModel
import DiffView
import Foundation
import ReviewTestSupport
import SwiftUI
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct CommandCatalogTests {
    private func key(_ shortcut: SeamCommand.Shortcut) -> String? {
        switch shortcut {
        case .command(let key, let modifiers), .single(let key, let modifiers):
            "\(key.character)-\(modifiers.rawValue)"
        case .commandWhen(let key, _): "\(key.character)-\(CommandModifiers.command.rawValue)"
        case .none: nil
        }
    }

    /// The catalog names keys by character so it needs no SwiftUI; each must be SwiftUI's own.
    @Test func namedKeysAreSwiftUIsKeyEquivalents() {
        let pairs: [(CommandKey, KeyEquivalent)] = [
            (.space, .space), (.return, .return), (.escape, .escape), (.delete, .delete),
            (.deleteForward, .deleteForward), (.tab, .tab), (.upArrow, .upArrow),
            (.downArrow, .downArrow), (.leftArrow, .leftArrow), (.rightArrow, .rightArrow),
            (.home, .home), (.end, .end), (.pageUp, .pageUp), (.pageDown, .pageDown),
        ]
        for (key, swiftUI) in pairs {
            #expect(KeyEquivalent(key) == swiftUI, "\(swiftUI)")
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
        #expect(try label("next-file") == "J")
        #expect(try label("page-up") == "⇧Space")
        #expect(try label("detected-base") == "")
    }

    @Test func worktreePositionsCountOnlyTheListedWorktrees() async throws {
        let repo = try await FixtureRepo()
        let gone = try await repo.worktree("gone", branch: "gone", from: "origin/main")
        try FileManager.default.removeItem(at: gone)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        let second = try #require(CommandCatalog.all.first { $0.id == "worktree-2" })
        #expect(second.isEnabled(session))

        session.hidesMissing = true

        #expect(!second.isEnabled(session))
    }

    @Test func tooltipsNameTheShortcutTheMenuUses() {
        #expect(CommandCatalog.help("Reload", command: "reload") == "Reload (R)")
        #expect(CommandCatalog.help("Threads", command: "threads") == "Threads (⇧⌘I)")
        #expect(
            CommandCatalog.help("Open", shortcut: CommandCatalog.openRepository) == "Open (⌘O)")
        // Every command a tooltip names exists and has a shortcut to show.
        for id in ["side-by-side", "reload", "threads", "base", "scope-all"] {
            #expect(CommandCatalog.help("x", command: id) != "x", "\(id)")
        }
    }

    /// The keys views handle themselves come from the catalog, the one key table.
    @Test func theDiffAndTheCardTakeTheirKeysFromTheCatalog() throws {
        #expect(
            CommandCatalog.diffKeyBindings == [
                DiffKeyBinding(" "): .pageDown, DiffKeyBinding(" ", shift: true): .pageUp,
            ])
        func event(_ key: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: 0, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: 36))
        }
        #expect(CommandCatalog.matches(try event("\r", .command), CommandCatalog.send))
        #expect(!CommandCatalog.matches(try event("\r", [.command, .shift]), CommandCatalog.send))
        #expect(!CommandCatalog.matches(try event("\r", []), CommandCatalog.send))
    }

    @Test func menuTitlesSayWhatTheCommandWillDo() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        let sidebar = try command("toggle-sidebar")
        #expect(sidebar.title(for: session) == "Hide Sidebar")

        sidebar.run(session)
        #expect(!session.showsWorktreeList)
        #expect(sidebar.title(for: session) == "Show Sidebar")
        #expect(sidebar.title(for: nil) == "Hide Sidebar")
    }

    @Test func goMenuNamesTheWorktreeEachNumberPicks() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()

        #expect(try command("worktree-1").title(for: session) == repo.main.lastPathComponent)
        #expect(try command("worktree-2").title(for: session) == tree.lastPathComponent)
        #expect(try command("worktree-3").title(for: session) == "Worktree 3")
    }

    @Test func specialKeysAreLabelledWithTheirSymbols() {
        #expect(SeamCommand.label(CommandKey.return, .command) == "⌘↩")
        #expect(SeamCommand.label(CommandKey.escape, []) == "⎋")
        #expect(SeamCommand.label(CommandKey.upArrow, .option) == "⌥↑")
        #expect(SeamCommand.label(CommandKey.downArrow, []) == "↓")
        #expect(SeamCommand.label(CommandKey.delete, .command) == "⌘⌫")
        #expect(SeamCommand.label(CommandKey.tab, .shift) == "⇧⇥")
        #expect(SeamCommand.label(CommandKey("g"), CommandModifiers([.command, .shift])) == "⇧⌘G")
    }

    @Test func theViewedCheckboxSaysHowItDiffersFromItsKey() {
        #expect(
            FileActions.viewedHelp(.unviewed)
                == "Mark as Viewed (V marks it and goes to the next unviewed file)")
        #expect(FileActions.viewedHelp(.viewed) == "Mark as Not Viewed")
    }
}
