import Foundation
import GitKit
import SeamCore

@MainActor
package enum CommandCatalog {
    private static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    package static let all: [SeamCommand] = file + find + view + go + review

    package static let byID = Dictionary(all.map { ($0.id, $0) }) { first, _ in first }

    /// A tooltip ending in the command's shortcut, read from the catalog so the two can't
    /// drift: "Reload (r)".
    /// A command's key as menus show it; empty when it has none.
    package static func shortcutLabel(of id: String) -> String {
        byID[id]?.shortcutLabel ?? ""
    }

    package static func help(_ text: String, command id: String) -> String {
        guard let label = byID[id]?.shortcutLabel, !label.isEmpty else { return text }
        return "\(text) (\(label))"
    }

    /// The selected worktree's, also in its row's context menu (`RowActions`).
    static let file: [SeamCommand] = [
        SeamCommand(
            id: "worktree-editor", title: localized("Open Worktree in Editor"), menu: .file,
            section: 0, shortcut: .none, isEnabled: { $0.selected?.worktree.isMissing == false },
            run: { session in session.selected.map { session.openWorktreeInEditor($0) } }),
        SeamCommand(
            id: "worktree-reveal", title: localized("Reveal Worktree in Finder"), menu: .file,
            section: 0, shortcut: .none, isEnabled: { $0.selected?.worktree.isMissing == false },
            run: { session in session.selected.map(session.revealWorktree) }),
        SeamCommand(
            id: "worktree-copy-path", title: localized("Copy Worktree Path"), menu: .file,
            section: 1, shortcut: .none,
            run: { session in session.selected.map { session.copyWorktreePath(of: $0) } }),
        SeamCommand(
            id: "worktree-copy-branch", title: localized("Copy Branch Name"), menu: .file,
            section: 1, shortcut: .none, isEnabled: { $0.selected?.worktree.branch != nil },
            run: { session in session.selected.map { session.copyBranchName(of: $0) } }),
        SeamCommand(
            id: "pull-request-open", title: localized("Open Pull Request in Browser"),
            menu: .file, section: 2, shortcut: .none,
            isEnabled: { $0.selected?.pullRequest != nil },
            run: { session in session.selected.map(session.openPullRequest) }),
        SeamCommand(
            id: "pull-request-copy", title: localized("Copy Pull Request URL"), menu: .file,
            section: 2, shortcut: .none, isEnabled: { $0.selected?.pullRequest != nil },
            run: { session in session.selected.map { session.copyPullRequestURL(of: $0) } }),
        SeamCommand(
            id: "pull-request-check", title: localized("Open Failed Check in Browser"),
            menu: .file, section: 2, shortcut: .none,
            isEnabled: { $0.selected?.pullRequest?.ciFailed == true },
            run: { session in session.selected.map(session.openFailedCheck) }),
    ]

    static let find: [SeamCommand] = [
        SeamCommand(
            id: "find", title: localized("Find…"), menu: .find, section: 0,
            shortcut: .commandWhen("f", .outsideFileList), run: { $0.find.show() }),
        SeamCommand(
            id: "find-next", title: localized("Find Next"), menu: .find, section: 0,
            shortcut: .command("g"), isEnabled: { $0.find.result.total > 0 },
            run: { $0.find.move(by: 1) }),
        SeamCommand(
            id: "find-previous", title: localized("Find Previous"), menu: .find, section: 0,
            shortcut: .command("g", [.command, .shift]), isEnabled: { $0.find.result.total > 0 },
            run: { $0.find.move(by: -1) }),
        SeamCommand(
            id: "filter-files", title: localized("Filter Files"), menu: .find, section: 1,
            shortcut: .commandWhen("f", .fileList),
            run: { session in
                session.selected?.navigator = .files
                session.filterFocusRequests += 1
            }),
        SeamCommand(
            id: "search", title: localized("Search in Review"), menu: .find, section: 1,
            shortcut: .command("f", [.command, .shift]), run: { $0.showSearch() }),
    ]

    static let view: [SeamCommand] = [
        SeamCommand(
            id: "toggle-sidebar", title: localized("Hide Sidebar"), menu: .view, section: 0,
            shortcut: .command("\\"), isEnabled: { _ in true },
            currentTitle: { $0.showsWorktreeList ? nil : localized("Show Sidebar") },
            run: { $0.showsWorktreeList.toggle() }),
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
            id: "carriage-returns", title: localized("Show Carriage Returns"), menu: .view,
            section: 2, shortcut: .none, isOn: { $0.settings.showsCarriageReturns },
            run: { $0.settings.showsCarriageReturns.toggle() }),
        SeamCommand(
            id: "flat-files", title: localized("Files as Flat List"), menu: .view, section: 2,
            shortcut: .none, isOn: { $0.selected?.flatFileList == true },
            run: { $0.selected?.flatFileList.toggle() }),
        SeamCommand(
            id: "sort-attention", title: localized("Sort Worktrees Needing You First"),
            menu: .view, section: 3, shortcut: .none, isEnabled: { _ in true },
            isOn: { $0.sort == .attention }, run: { $0.sort = .attention }),
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
                id: "threads", title: localized("Show Threads"), menu: .go, section: 0,
                shortcut: .command("i", [.command, .shift]), run: { $0.showsThreads = true }),
            SeamCommand(
                id: "next-inbox", title: localized("Next Awaiting You"), menu: .go, section: 0,
                shortcut: .command("]", [.command, .option]),
                isEnabled: { !$0.inbox.isEmpty },
                run: { session in Task { await session.openNextInInbox() } }),
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
                section: 1, shortcut: .command(CommandKey(Character(String(position)))),
                isEnabled: { $0.sortedReviews.count >= position },
                currentTitle: { session in
                    let reviews = session.sortedReviews
                    return reviews.indices.contains(position - 1)
                        ? reviews[position - 1].worktree.name : nil
                },
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
                id: "next-thread", title: localized("Next Thread"), menu: .go, section: 2,
                shortcut: .single("m"),
                isEnabled: { $0.selected?.steppableThreads.isEmpty == false },
                run: { $0.moveThread(by: 1) }),
            SeamCommand(
                id: "previous-thread", title: localized("Previous Thread"), menu: .go,
                section: 2, shortcut: .single("m", .shift),
                isEnabled: { $0.selected?.steppableThreads.isEmpty == false },
                run: { $0.moveThread(by: -1) }),
            SeamCommand(
                id: "next-commit", title: localized("Next Commit"), menu: .go, section: 2,
                shortcut: .single("l"), isEnabled: { $0.selected?.commitStep(by: 1) != nil },
                run: { session in session.selected?.stepCommit(by: 1) }),
            SeamCommand(
                id: "previous-commit", title: localized("Previous Commit"), menu: .go,
                section: 2, shortcut: .single("l", .shift),
                isEnabled: { $0.selected?.commitStep(by: -1) != nil },
                run: { session in session.selected?.stepCommit(by: -1) }),
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
            id: "scope-committed", title: localized("Committed Changes"), menu: .review,
            section: 0, shortcut: .single("2"),
            isOn: { $0.selected?.isShowing(.committed) == true },
            run: { $0.setScope(.committed) }),
        SeamCommand(
            id: "scope-uncommitted", title: localized("Uncommitted Changes"), menu: .review,
            section: 0, shortcut: .single("3"),
            isOn: { $0.selected?.isShowing(.uncommitted) == true },
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
            id: "copy-commit-id", title: localized("Copy Commit ID"), menu: .review, section: 1,
            shortcut: .none, isEnabled: { $0.selected?.newestSelectedCommit != nil },
            run: { session in
                session.selected?.newestSelectedCommit.map { session.copyCommitID($0) }
            }),
        SeamCommand(
            id: "copy-commit-subject", title: localized("Copy Commit Subject"), menu: .review,
            section: 1, shortcut: .none, isEnabled: { $0.selected?.newestSelectedCommit != nil },
            run: { session in
                session.selected?.newestSelectedCommit.map { session.copySubject(of: $0) }
            }),
        SeamCommand(
            id: "viewed", title: localized("Mark as Viewed"), menu: .review, section: 2,
            shortcut: .single("v"),
            currentTitle: { session in
                guard let review = session.selected, let path = review.currentFile,
                    review.viewedStatus(path) == .viewed
                else { return nil }
                return localized("Mark as Not Viewed")
            },
            run: { $0.toggleViewed() }),
        SeamCommand(
            id: "since-viewed", title: localized("Show Changes Since Viewed"), menu: .review,
            section: 2, shortcut: .single("v", .shift),
            isEnabled: { session in
                guard let review = session.selected, let path = review.currentFile else {
                    return false
                }
                return review.sinceViewed[path] != nil || review.sinceViewedID(path) != nil
            },
            currentTitle: { session in
                guard let review = session.selected, let path = review.currentFile,
                    review.sinceViewed[path] != nil
                else { return nil }
                return localized("Show Full Diff")
            },
            run: { session in Task { await session.toggleSinceViewed() } }),
        SeamCommand(
            id: "editor", title: localized("Open in Editor"), menu: .review, section: 2,
            shortcut: .single("o"), run: { $0.openInEditor() }),
        SeamCommand(
            id: "copy-path", title: localized("Copy Path"), menu: .review, section: 2,
            shortcut: .command("c", [.command, .option]),
            isEnabled: { $0.selected?.currentFile != nil },
            run: { session in
                session.selected?.currentFile.map { session.copyPath($0, relative: false) }
            }),
        SeamCommand(
            id: "copy-relative-path", title: localized("Copy Relative Path"), menu: .review,
            section: 2, shortcut: .command("c", [.command, .option, .shift]),
            isEnabled: { $0.selected?.currentFile != nil },
            run: { session in
                session.selected?.currentFile.map { session.copyPath($0, relative: true) }
            }),
        SeamCommand(
            id: "reveal", title: localized("Reveal in Finder"), menu: .review, section: 2,
            shortcut: .command("r", [.command, .shift]),
            isEnabled: { $0.selected?.currentFile != nil },
            run: { session in session.selected?.currentFile.map(session.revealInFinder) }),
        SeamCommand(
            id: "collapse", title: localized("Collapse File"), menu: .review, section: 2,
            shortcut: .single("x"),
            currentTitle: { session in
                guard let review = session.selected, let path = review.currentFile,
                    review.collapsed.contains(path)
                else { return nil }
                return localized("Expand File")
            },
            run: { $0.toggleCollapsed() }),
        SeamCommand(
            id: "base", title: localized("Choose Base…"), menu: .review, section: 3,
            shortcut: .single("b"),
            run: { session in
                // The picker opens from the commit list, so that has to be showing.
                session.showsWorktreeList = true
                session.showsBasePicker.toggle()
            }),
        SeamCommand(
            id: "keep-parent", title: localized("Keep Parent That Looks Merged"), menu: .review,
            section: 3, shortcut: .none, isEnabled: { $0.selected?.staleParent != nil },
            run: { $0.dismissStaleParent() }),
        SeamCommand(
            id: "pull-request-base", title: localized("Use Pull Request's Base"), menu: .review,
            section: 3, shortcut: .none, isEnabled: { $0.selected?.pullRequestBase != nil },
            run: { $0.usePullRequestBase() }),
        SeamCommand(
            id: "keep-detected-base", title: localized("Keep Detected Base"), menu: .review,
            section: 3, shortcut: .none, isEnabled: { $0.selected?.pullRequestBase != nil },
            run: { $0.dismissPullRequestBase() }),
        SeamCommand(
            id: "detected-base", title: localized("Use Detected Base"), menu: .review,
            section: 3, shortcut: .none, isEnabled: { $0.selected?.baseOverride != nil },
            run: { $0.setBaseOverride(nil) }),
        SeamCommand(
            id: "reload", title: localized("Reload"), menu: .review, section: 4,
            shortcut: .single("r"), run: { $0.reload() }),
        SeamCommand(
            id: "comment", title: localized("Comment…"), menu: .review, section: 5,
            shortcut: .single("c"), isEnabled: { $0.threads != nil && $0.selected?.diff != nil },
            run: { $0.comment() }),
        SeamCommand(
            id: "open-thread", title: localized("Open Thread on This Line"), menu: .review,
            section: 5, shortcut: .single("t"),
            isEnabled: { $0.selected?.placedThreads.isEmpty == false },
            run: { $0.openThreadAtCursor() }),
        SeamCommand(
            id: "resolve-thread", title: localized("Resolve Thread"), menu: .review, section: 5,
            shortcut: .none, isEnabled: { $0.selectedThread != nil },
            currentTitle: {
                $0.selectedThread?.isResolved == true ? localized("Reopen Thread") : nil
            },
            run: { session in
                guard let thread = session.selectedThread else { return }
                Task { await session.setResolved(!thread.isResolved, thread: thread.id) }
            }),
        SeamCommand(
            id: "delete-thread", title: localized("Delete Thread"), menu: .review, section: 5,
            shortcut: .none, isEnabled: { $0.selectedThread != nil },
            run: { session in
                guard let id = session.selectedThreadID else { return }
                Task { await session.deleteThread(id) }
            }),
        SeamCommand(
            id: "thread-commit", title: localized("Jump to Thread's Commit"), menu: .review,
            section: 5, shortcut: .single("t", .shift),
            isEnabled: { session in
                session.openThread.flatMap { session.selected?.commitsUpTo($0) } != nil
            },
            run: { session in
                guard let thread = session.openThread else { return }
                Task { await session.jumpToCommit(of: thread) }
            }),
        SeamCommand(
            id: "thread-on-github", title: localized("Open Thread on GitHub"), menu: .review,
            section: 5, shortcut: .none, isEnabled: { $0.selectedGitHubThread != nil },
            run: { session in session.selectedGitHubThread.map(session.openOnGitHub) }),
        SeamCommand(
            id: "resolved-threads", title: localized("Show Resolved Threads"), menu: .review,
            section: 6, shortcut: .none, isOn: { $0.settings.showsResolvedThreads },
            run: { $0.settings.showsResolvedThreads.toggle() }),
        SeamCommand(
            id: "agent-prompt", title: localized("Copy Prompt for Agent"), menu: .review,
            section: 6, shortcut: .none,
            run: { session in Task { await session.copyAgentPrompt() } }),
    ]

    package static func items(in menu: SeamCommand.Menu) -> [SeamCommand] {
        all.filter { $0.menu == menu }
    }
}

extension RepoSession {
    /// The open thread, when it's one of Seam's own: GitHub's can't be resolved or deleted.
    fileprivate var selectedThread: ReviewThread? {
        selectedThreadID.flatMap { id in threads?.threads.first { $0.id == id } }
    }

    /// The open thread, Seam's or a pull request's.
    var openThread: ReviewThread? {
        selectedThreadID.flatMap { id in selected?.placedThreads.first { $0.id == id }?.thread }
    }

    var selectedGitHubThread: ReviewThread? {
        selectedThreadID.flatMap { id in selected?.placedThreads.first { $0.id == id }?.thread }
            .flatMap { $0.capabilities.contains(.openRemote) ? $0 : nil }
    }
}
