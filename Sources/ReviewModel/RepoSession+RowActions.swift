import Foundation
import SeamCore

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
    package func copyWorktreePath(of review: WorktreeReview) {
        services.platform.copy(review.worktree.path.path)
    }

    package func copyBranchName(of review: WorktreeReview) {
        guard let branch = review.worktree.branch else { return }
        services.platform.copy(branch)
    }

    package func copyCommitID(_ commit: ReviewCommit) {
        services.platform.copy(commit.id)
    }

    package func copySubject(of commit: ReviewCommit) {
        services.platform.copy(commit.subject)
    }

    package func revealWorktree(_ review: WorktreeReview) {
        services.platform.reveal(review.worktree.path)
    }

    /// Opens the worktree's folder; a failure shows on that worktree's banner.
    package func openWorktreeInEditor(_ review: WorktreeReview, command: EditorCommand? = nil) {
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
