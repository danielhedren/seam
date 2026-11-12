import Foundation
import GitKit
import SeamCore

extension RepoSession {
    func startPullRequests(in repository: Repository) {
        let pullRequests = RepoPullRequests(
            services: services, directory: repository.anchor, saved: savedPullRequests,
            branches: { [weak self] in self?.pullRequestBranches ?? [] })
        pullRequests.onRead = { [weak self] saved, repo in
            await self?.readPullRequestThreads(saved, repo: repo)
        }
        pullRequests.listsOthers = { [settings] in settings.showsPullRequestList }
        pullRequests.readsInvolvement = { [weak self] in
            self?.pullRequestFilter.onlyInvolvingMe == true
        }
        pullRequests.readsInBackground = { [settings] in
            settings.showsPullRequests
                && settings.notifications.contains(where: \.needsPullRequests)
        }
        pullRequests.onUpdate = { [weak self, weak pullRequests] in
            guard let self, let pullRequests else { return }
            self.notePullRequests(pullRequests.saved)
        }
        setPullRequests(pullRequests)
    }

    /// GitHub's threads for every worktree's PR and every opened pull request review (SPEC §7.9).
    func readPullRequestThreads(_ saved: SavedPullRequests, repo: GitHubRepo) async {
        var targets = Dictionary(
            reviews.map { review in
                (review.id, review.worktree.branch.flatMap { saved.byBranch[$0] })
            },
            uniquingKeysWith: { first, _ in first })
        for review in pullRequestReviews {
            targets[review.id] = review.pullRequest
        }
        await pullRequestThreads?.reconcile(targets, repo: repo)
    }

    /// Every worktree's branch and every local parent's, whose merged PR marks it stale.
    var pullRequestBranches: [String] {
        var branches = Set(reviews.compactMap(\.worktree.branch))
        for review in reviews {
            if let parent = review.detection?.parent?.ref, parent.hasPrefix(RefName.heads) {
                branches.insert(RefName.shortBranch(parent))
            }
        }
        return branches.sorted()
    }

    /// The app came to the front; the PRs are read again if they're older than a minute.
    package func noteActivation(_ isActive: Bool) {
        isAppActive = isActive
        pullRequests?.appIsActive = isActive
        if isActive { pullRequests?.request(.activation) }
    }

    /// Settings turned pull requests on or off, or asked gh to check again. Off, the threads
    /// `seam` would list are cleared rather than left to go stale.
    package func refreshPullRequests() async {
        if !settings.showsPullRequests {
            await pullRequestThreads?.clearAll()
            return
        }
        pullRequests?.request(.settings)
    }

    package func openPullRequest(of review: WorktreeReview) {
        guard let url = review.pullRequest.flatMap({ URL(string: $0.url) }) else { return }
        services.platform.open(url)
    }

    package func copyPullRequestURL(of review: WorktreeReview) {
        guard let url = review.pullRequest?.url else { return }
        services.platform.copy(url)
    }

    /// The bare number, as `gh pr` commands take it.
    package func copyPullRequestNumber(of review: WorktreeReview) {
        guard let number = review.pullRequest?.number else { return }
        services.platform.copy(String(number))
    }

    package func openFailedCheck(of review: WorktreeReview) {
        guard let pullRequest = review.pullRequest, pullRequest.ciFailed,
            let url = URL(string: pullRequest.checks.failedURL ?? pullRequest.url + "/checks")
        else { return }
        services.platform.open(url)
    }

    package func usePullRequestBase() {
        guard let base = selected?.pullRequestBase else { return }
        setBaseOverride(base.ref)
    }
}
