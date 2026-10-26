import AppKit
import ReviewModel
import SeamCore
import SwiftUI

/// The worktree and commit rows' context menus (SPEC §7.2, §7.2.1). Their menu-bar twins in
/// `CommandCatalog` act on the selected worktree and the newest selected commit.
@MainActor
enum RowActions {
    typealias Action = FileActions.Action

    private static func localized(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    static func actions(for review: WorktreeReview, in session: RepoSession) -> [[Action]] {
        let exists = !review.worktree.isMissing
        var copies = [
            Action(title: localized("Copy Path")) { session.copyWorktreePath(of: review) }
        ]
        if review.worktree.branch != nil {
            copies.append(
                Action(title: localized("Copy Branch Name")) {
                    session.copyBranchName(of: review)
                })
        }
        var groups = [
            [
                Action(title: localized("Open in Editor"), isEnabled: exists) {
                    session.openWorktreeInEditor(review)
                },
                Action(title: localized("Reveal in Finder"), isEnabled: exists) {
                    session.revealWorktree(review)
                },
            ],
            copies,
        ]
        if review.pullRequest != nil {
            groups.append([
                Action(title: localized("Open Pull Request in Browser")) {
                    session.openPullRequest(of: review)
                },
                Action(title: localized("Copy Pull Request URL")) {
                    session.copyPullRequestURL(of: review)
                },
            ])
        }
        return groups
    }

    /// For the rows a right-click picked: the newest of them, as in the menu bar.
    static func actions(
        for picked: Set<CommitSelection.End>, of review: WorktreeReview, in session: RepoSession
    ) -> [[Action]] {
        guard
            let commit = review.commitLog?.commits.first(where: { picked.contains(.commit($0.id)) })
        else { return [] }
        let only = CommitSelection(newest: .commit(commit.id), oldest: .commit(commit.id))
        var selection = [
            Action(
                title: localized("Show Only This Commit"),
                isEnabled: review.shownSelection != only
            ) { session.selectCommits(only) }
        ]
        if !review.isShowing(.all) {
            selection.append(
                Action(title: localized("Show All Changes")) { session.setScope(.all) })
        }
        return [
            [
                Action(title: localized("Copy Commit ID")) { session.copyCommitID(commit) },
                Action(title: localized("Copy Subject")) { session.copySubject(of: commit) },
            ],
            selection,
        ]
    }
}

extension WorktreeReview {
    /// What Copy Commit ID copies from the menu bar: the newest commit the diff covers.
    var newestSelectedCommit: ReviewCommit? {
        guard let log = commitLog, let shown = shownSelection else { return nil }
        let ends = log.ends
        guard let newest = ends.firstIndex(of: shown.newest),
            let oldest = ends.firstIndex(of: shown.oldest), newest <= oldest
        else { return nil }
        return ends[newest...oldest].lazy.compactMap { end in
            guard case .commit(let id) = end else { return nil }
            return log.commits.first { $0.id == id }
        }.first
    }
}

extension RepoSession {
    func copyWorktreePath(of review: WorktreeReview) {
        services.platform.copy(review.worktree.path.path)
    }

    func copyBranchName(of review: WorktreeReview) {
        guard let branch = review.worktree.branch else { return }
        services.platform.copy(branch)
    }

    func copyCommitID(_ commit: ReviewCommit) {
        services.platform.copy(commit.id)
    }

    func copySubject(of commit: ReviewCommit) {
        services.platform.copy(commit.subject)
    }

    func revealWorktree(_ review: WorktreeReview) {
        NSWorkspace.shared.activateFileViewerSelecting([review.worktree.path])
    }

    /// Opens the worktree's folder; a failure shows on that worktree's banner.
    func openWorktreeInEditor(_ review: WorktreeReview, command: EditorCommand? = nil) {
        guard !review.worktree.isMissing else { return }
        launchEditor(
            (command ?? services.settings.editor).commandLine(directory: review.worktree.path.path),
            for: review)
    }
}

extension EditorCommand {
    /// The template without its line: `{line}` goes, with the option before it that takes it
    /// (`--line {line}`, `-g {path}:{line}`), so the editor opens the folder itself.
    func commandLine(directory: String) -> String {
        var words: [Substring] = []
        for word in template.split(separator: " ") {
            guard word.contains("{line}") else {
                words.append(word)
                continue
            }
            if words.count > 1, words.last?.hasPrefix("-") == true { words.removeLast() }
            if word.contains("{path}") { words.append("{path}") }
        }
        return words.joined(separator: " ")
            .replacingOccurrences(of: "{path}", with: Self.quoted(directory))
    }
}
