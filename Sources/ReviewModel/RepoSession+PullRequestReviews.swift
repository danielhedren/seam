import Foundation
import GitKit
import SeamCore

/// Reviewing a listed pull request from Seam's store (SPEC §6.4, §7.2.2, §8.3.1).
extension RepoSession {
    /// Opens the PR's review; without a store to fetch it into, it opens on GitHub instead.
    package func openPullRequestReview(_ number: Int) {
        guard pullRequestStore != nil, let pullRequest = listedPullRequest(number) else {
            openListedPullRequest(number)
            return
        }
        noteOpened(.pullRequest(repo: directory.path, number: number))
        let id = WorktreeReview.id(ofPullRequest: number)
        if !pullRequestReviews.contains(where: { $0.id == id }), let store = pullRequestStore {
            let review = WorktreeReview(
                pullRequest: pullRequest, store: store.directory, services: services)
            review.pullRequests = pullRequests
            review.restore(pullRequestReviewStates[String(number)], override: nil)
            review.fetch = { [weak self] again in
                await self?.fetchListedPullRequests(again: again)
            }
            pullRequestReviews.append(review)
        }
        select(id)
    }

    /// Brings the store up to date with every listed PR and every opened one, in one fetch, and
    /// only when a head or base moved since the last. `again` starts the store afresh.
    func fetchListedPullRequests(again: Bool = false) async -> GitError? {
        guard let store = pullRequestStore, let repo = pullRequests?.repo else { return nil }
        if let running = storeFetch { return await running.value }
        let opened = pullRequestReviews.compactMap(\.pullRequest)
        let listed = pullRequestListing.rows.filter { !$0.isHidden }.map(\.pullRequest)
        let wanted = Dictionary(
            (listed + opened).map { ($0.number, "\($0.headCommit) \($0.baseCommit)") },
            uniquingKeysWith: { first, _ in first })
        if !again, wanted.allSatisfy({ fetchedPullRequests[$0.key] == $0.value }) { return nil }
        let bases = Set((listed + opened).map(\.base))
        let task = Task { () -> GitError? in
            if again { await store.reset() }
            do throws(GitError) {
                try await store.fetch(
                    pullRequests: wanted.keys.sorted(), bases: bases.sorted(), from: repo)
                return nil
            } catch {
                return error
            }
        }
        storeFetch = task
        let failure = await task.value
        storeFetch = nil
        if failure == nil {
            fetchedPullRequests = wanted
        } else if again {
            fetchedPullRequests = [:]
        }
        return failure
    }

    /// After a read: opened reviews follow their PR, closed ones go, and what's listed is
    /// fetched in the background so opening one rarely waits.
    func notePullRequestReviews(_ saved: SavedPullRequests) {
        guard let open = saved.open else { return }
        let byNumber = Dictionary(
            open.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        for review in pullRequestReviews {
            guard let number = review.pullRequest?.number else { continue }
            if let pullRequest = byNumber[number] { review.update(pullRequest) }
        }
        let closed = pullRequestReviews.filter { review in
            review.pullRequest.map { byNumber[$0.number] == nil } ?? true
        }
        if closed.contains(where: { $0.id == selectedID }),
            let main = reviews.first(where: \.worktree.isMain)
        {
            select(main.id)
        }
        pullRequestReviews.removeAll { review in closed.contains { $0 === review } }
        pullRequestReviewStates = pullRequestReviewStates.filter { key, _ in
            Int(key).map { byNumber[$0] != nil } ?? false
        }
        guard pullRequestStore != nil else { return }
        Task { [weak self] in _ = await self?.fetchListedPullRequests() }
    }
}
