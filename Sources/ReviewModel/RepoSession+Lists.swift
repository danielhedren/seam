import Foundation
import SeamCore

/// A command palette row (SPEC §7.5): a menu command that applies now, or a jump to a worktree.
package struct PaletteEntry: Identifiable {
    package var id: String
    package var title: String
    /// The menu the command is in, so the reader learns where to find it next time.
    package var menu: String
    package var shortcut: String
    package var isOn = false
    package var run: @MainActor () -> Void
}

/// The lists the palette, the switcher, the Inbox and the thread panel show, ordered and
/// grouped here so they're tested without a window.
extension RepoSession {
    /// The menu's commands that apply now, then a jump to each worktree, which takes the place
    /// of Go › Worktree 1…9; with a query, best match first.
    package func paletteEntries(matching query: String = "") -> [PaletteEntry] {
        let commands = CommandCatalog.all.filter {
            !$0.id.hasPrefix("worktree-") && $0.isEnabled(self)
        }
        .map { command in
            PaletteEntry(
                id: command.id, title: command.title(for: self), menu: command.menu.name,
                shortcut: command.shortcutLabel(for: self), isOn: command.isOn?(self) ?? false
            ) { command.run(self) }
        }
        let worktrees = sortedReviews.enumerated().map { position, review in
            PaletteEntry(
                id: "go:" + review.id,
                title: String(localized: "Go to \(review.worktree.name)", bundle: .module),
                menu: SeamCommand.Menu.go.name,
                shortcut: position < 9
                    ? SeamCommand.label(CommandKey(Character(String(position + 1))), .command)
                    : ""
            ) { [weak self] in self?.select(review.id) }
        }
        let entries = commands + worktrees
        guard !query.isEmpty else { return entries }
        return entries.compactMap { entry in
            FuzzyMatch.score(query, in: entry.title).map { (entry, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// The switcher's worktrees by name or branch, best match first; ties keep the sidebar's
    /// order.
    package func worktrees(matching query: String) -> [WorktreeReview] {
        sortedReviews
            .enumerated()
            .compactMap { position, review -> (WorktreeReview, Int, Int)? in
                let name = FuzzyMatch.score(query, in: review.worktree.name)
                let branch = review.worktree.branch.flatMap { FuzzyMatch.score(query, in: $0) }
                guard let best = [name, branch].compactMap(\.self).max() else { return nil }
                return (review, best, position)
            }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }

    /// The Inbox by worktree, newest first, so the worktree with the latest word leads.
    package var inboxGroups: [(worktree: String, items: [InboxItem])] {
        var order: [String] = []
        var byWorktree: [String: [InboxItem]] = [:]
        for item in inbox {
            if byWorktree[item.worktree] == nil { order.append(item.worktree) }
            byWorktree[item.worktree, default: []].append(item)
        }
        return order.map { ($0, byWorktree[$0] ?? []) }
    }
}

extension WorktreeReview {
    /// Threads' threads by file, in the order they're placed, leaving out `excluded`
    /// (those Awaiting You shows above them).
    package func threadGroups(excluding excluded: Set<String> = [])
        -> [(path: String, threads: [PlacedThread])]
    {
        var order: [String] = []
        var byPath: [String: [PlacedThread]] = [:]
        for item in placedThreads where !excluded.contains(item.id) {
            let path = item.path
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append(item)
        }
        return order.map { ($0, byPath[$0] ?? []) }
    }
}
