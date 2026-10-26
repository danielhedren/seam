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
