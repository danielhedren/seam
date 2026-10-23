import Testing

@testable import Features

/// Help › Keyboard Shortcuts (SPEC §9), generated from the catalog.
@MainActor
struct ShortcutSheetTests {
    @Test func listsEveryShortcutOnceByMenuInMenuBarOrder() {
        let groups = ShortcutSheet.groups
        #expect(groups.map(\.menu) == ["File", "Edit › Find", "View", "Go", "Review"])
        let ids = groups.flatMap { $0.entries.map(\.id) }
        let withShortcuts = CommandCatalog.all.filter { !$0.shortcutLabel.isEmpty }.map(\.id)
        #expect(ids == ["new-window", "open-repository"] + withShortcuts)
    }

    @Test func eachEntryShowsTheMenusLabelAndWhereTheKeyWorks() throws {
        let entries = ShortcutSheet.groups.flatMap(\.entries)
        func entry(_ id: String) throws -> ShortcutSheet.Entry {
            try #require(entries.first { $0.id == id })
        }
        #expect(try entry("new-window").shortcut == "⌘N")
        #expect(
            try entry("switcher")
                == .init(id: "switcher", title: "Switch Worktree…", shortcut: "⌘K"))
        #expect(try entry("next-file").shortcut == "J")
        #expect(try entry("next-file").note == "In the diff or file list")
        #expect(try entry("filter-files").shortcut == "⌘F")
        #expect(try entry("filter-files").note == "In the file list")
        #expect(try entry("find").note == "Outside the file list")
        #expect(!entries.contains { $0.id == "flat-files" })
    }

    @Test func searchMatchesTitlesShortcutsAndMenus() {
        let hunks = ShortcutSheet.groups(matching: "hunk")
        #expect(hunks.map(\.menu) == ["Go"])
        #expect(hunks.first?.entries.map(\.title) == ["Next Hunk", "Previous Hunk"])
        #expect(
            ShortcutSheet.groups(matching: "⇧⌘g").flatMap(\.entries).map(\.id) == [
                "find-previous"
            ])
        let view = ShortcutSheet.groups.first { $0.menu == "View" }
        #expect(
            ShortcutSheet.groups(matching: "view").first { $0.menu == "View" } == view,
            "a menu's name matches all of its entries")
        #expect(ShortcutSheet.groups(matching: "zzz").isEmpty)
        #expect(ShortcutSheet.groups(matching: " ") == ShortcutSheet.groups)
    }
}
