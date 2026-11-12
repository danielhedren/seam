import Foundation
import GitKit
import SeamCore

/// Other people's open pull requests, under the worktrees (SPEC §7.2.2).
extension RepoSession {
    /// Whether the list shows: gh read the repo's open PRs, and neither setting is off.
    package var showsPullRequestList: Bool {
        settings.showsPullRequests && settings.showsPullRequestList
            && pullRequests?.saved.open != nil
    }

    package var pullRequestListing: PullRequestListing {
        let saved = pullRequests?.saved ?? SavedPullRequests()
        return PullRequestListing(
            open: saved.open ?? [], viewer: saved.viewer,
            reviewRequests: saved.reviewRequests ?? [], checkedOut: checkedOutPullRequests,
            filter: pullRequestFilter, showsHidden: showsHiddenPullRequests)
    }

    /// The open PRs a worktree here has checked out; its row already shows them.
    var checkedOutPullRequests: Set<Int> {
        Set(
            reviews.compactMap { review in
                review.pullRequest.flatMap { $0.state == .open ? $0.number : nil }
            })
    }

    /// What notifications compare for the list; nil until it was read this session.
    var listedSnapshot: NotificationSnapshot.Listed? {
        guard pullRequests?.hasRead == true, showsPullRequestList else { return nil }
        let saved = pullRequests?.saved ?? SavedPullRequests()
        let everything = PullRequestListing(
            open: saved.open ?? [], viewer: saved.viewer, reviewRequests: [],
            checkedOut: checkedOutPullRequests, filter: PullRequestFilter())
        let listing = pullRequestListing
        return NotificationSnapshot.Listed(
            known: Set(everything.rows.map(\.id)).union(listing.rows.map(\.id)),
            shown: Dictionary(
                listing.rows.filter { !$0.isHidden }.map { ($0.id, $0.pullRequest) },
                uniquingKeysWith: { first, _ in first }),
            reviewRequests: saved.reviewRequests ?? [])
    }

    func listedPullRequest(_ number: Int) -> PullRequest? {
        pullRequests?.saved.open?.first { $0.number == number }
    }

    // MARK: - Rows

    package func openListedPullRequest(_ number: Int) {
        guard let url = listedPullRequest(number).flatMap({ URL(string: $0.url) }) else { return }
        services.platform.open(url)
        noteOpened(.pullRequest(repo: directory.path, number: number))
    }

    package func copyListedPullRequestURL(_ number: Int) {
        guard let pullRequest = listedPullRequest(number) else { return }
        services.platform.copy(pullRequest.url)
    }

    package func copyListedPullRequestNumber(_ number: Int) {
        services.platform.copy(String(number))
    }

    /// For checking a PR out by hand; Seam runs nothing in the repo (SPEC §5.5).
    package func copyWorktreeCommand(for number: Int) {
        let remote = pullRequests?.remote ?? "origin"
        services.platform.copy(
            "git fetch \(remote) pull/\(number)/head:pr-\(number) && "
                + "git worktree add ../pr-\(number) pr-\(number)")
    }

    // MARK: - Filters

    package func hidePullRequest(_ number: Int) {
        pullRequestFilter.hiddenNumbers.insert(number)
    }

    /// Hides one author's PRs, whichever way the authors filter works.
    package func hidePullRequests(by author: String) {
        switch pullRequestFilter.authors.mode {
        case .hide: pullRequestFilter.authors.values.insert(author)
        case .showOnly: pullRequestFilter.authors.values.remove(author)
        }
    }

    /// Checks or unchecks an author or label in the filter menu.
    package func setChecked(
        _ value: String, _ checked: Bool,
        in keyPath: WritableKeyPath<PullRequestFilter, PullRequestFilter.Checked>
    ) {
        if checked {
            pullRequestFilter[keyPath: keyPath].values.insert(value)
        } else {
            pullRequestFilter[keyPath: keyPath].values.remove(value)
        }
    }

    /// Turns every filter off, the PRs hidden one by one included.
    package func clearPullRequestFilters() {
        pullRequestFilter = PullRequestFilter()
    }
}
