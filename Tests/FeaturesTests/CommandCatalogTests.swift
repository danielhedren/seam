import Foundation
import SwiftUI
import TestSupport
import Testing

@testable import Features

@MainActor @Suite struct CommandCatalogTests {
    private func key(_ shortcut: SeamCommand.Shortcut) -> String? {
        switch shortcut {
        case .command(let key, let modifiers), .single(let key, let modifiers):
            "\(key.character)-\(modifiers.rawValue)"
        case .commandWhen(let key, _): "\(key.character)-\(EventModifiers.command.rawValue)"
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
        #expect(CommandCatalog.help("Threads", command: "thread-panel") == "Threads (⌥⌘0)")
        #expect(
            CommandCatalog.help("Open", shortcut: CommandCatalog.openRepository) == "Open (⌘O)")
        // Every command a tooltip names exists and has a shortcut to show.
        for id in ["side-by-side", "reload", "thread-panel", "base", "scope-all"] {
            #expect(CommandCatalog.help("x", command: id) != "x", "\(id)")
        }
    }

    private func command(_ id: String) throws -> SeamCommand {
        try #require(CommandCatalog.all.first { $0.id == id })
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

    @Test func paletteJumpsToWorktreesWithTheirShortcutsAndShowsWhatIsOn() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()

        let entries = CommandPalette.entries(for: session)

        #expect(!entries.contains { $0.id.hasPrefix("worktree-") })
        let jump = try #require(entries.first { $0.id == "go:" + tree.path })
        #expect(jump.title == "Go to \(tree.lastPathComponent)")
        #expect(jump.shortcut == "⌘2")
        #expect(entries.first { $0.id == "scope-all" }?.isOn == true)
        #expect(entries.first { $0.id == "scope-all" }?.menu == "Review")
        #expect(entries.first { $0.id == "find" }?.shortcut == "⌘F")
        #expect(entries.first { $0.id == "filter-files" }?.shortcut == "")
    }

    @Test func specialKeysAreLabelledWithTheirSymbols() {
        #expect(SeamCommand.label(.return, .command) == "⌘↩")
        #expect(SeamCommand.label(.escape, []) == "⎋")
        #expect(SeamCommand.label(.upArrow, .option) == "⌥↑")
        #expect(SeamCommand.label(.downArrow, []) == "↓")
        #expect(SeamCommand.label(.delete, .command) == "⌘⌫")
        #expect(SeamCommand.label(.tab, .shift) == "⇧⇥")
        #expect(SeamCommand.label("g", [.command, .shift]) == "⇧⌘G")
    }
}
