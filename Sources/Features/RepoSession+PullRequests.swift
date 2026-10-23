import AppKit
import Foundation
import GitKit
import SeamCore

extension RepoSession {
    func startPullRequests(in repository: Repository) {
        let pullRequests = RepoPullRequests(
            services: services, directory: repository.anchor, saved: savedPullRequests,
            branches: { [weak self] in self?.pullRequestBranches ?? [] },
            worktrees: { [weak self] in
                Dictionary(
                    (self?.reviews ?? []).compactMap { review in
                        review.worktree.branch.map { ($0, review.id) }
                    }, uniquingKeysWith: { first, _ in first })
            })
        pullRequests.onThreads = { [weak self] worktree, threads in
            await self?.threads?.saveGitHub(threads, worktree: worktree)
        }
        pullRequests.onUpdate = { [weak self, weak pullRequests] in
            guard let self, let pullRequests else { return }
            self.notePullRequests(pullRequests.saved)
        }
        setPullRequests(pullRequests)
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
    func noteActivation(_ isActive: Bool) {
        pullRequests?.appIsActive = isActive
        if isActive { pullRequests?.request(.activation) }
    }

    /// Settings turned pull requests on, or asked gh to check again.
    func refreshPullRequests() {
        pullRequests?.request(.settings)
    }

    func openPullRequest(of review: WorktreeReview) {
        guard let url = review.pullRequest.flatMap({ URL(string: $0.url) }) else { return }
        services.openURL(url)
    }

    func copyPullRequestURL(of review: WorktreeReview, to pasteboard: NSPasteboard = .general) {
        guard let url = review.pullRequest?.url else { return }
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    func openFailedCheck(of review: WorktreeReview) {
        guard let pullRequest = review.pullRequest, pullRequest.ciFailed,
            let url = URL(string: pullRequest.checks.failedURL ?? pullRequest.url + "/checks")
        else { return }
        services.openURL(url)
    }

    func usePullRequestBase() {
        guard let base = selected?.pullRequestBase else { return }
        setBaseOverride(base.ref)
    }
}
