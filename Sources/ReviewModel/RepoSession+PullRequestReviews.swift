import Foundation
import GitKit
import SeamCore

/// Reviewing a listed pull request from Seam's store (SPEC §6.4, §7.2.2, §8.3.1).
extension RepoSession {
    /// Opens the PR's review; without a store to fetch it into, it opens on GitHub instead. One
    /// the list doesn't know yet, as on a notification's click before the first read, or not
    /// at all, is looked up first.
    package func openPullRequestReview(_ number: Int) {
        if let pullRequest = listedPullRequest(number) {
            open(pullRequest)
            return
        }
        Task { [weak self] in
            guard let pullRequests = self?.pullRequests else { return }
            await pullRequests.answered()
            guard let self else { return }
            if let pullRequest = listedPullRequest(number) {
                open(pullRequest)
            } else if let repo = pullRequests.repo,
                let pullRequest = try? await services.github.client.pullRequest(number, in: repo),
                pullRequest.state == .open
            {
                open(pullRequest)
            }
        }
    }

    private func open(_ pullRequest: PullRequest) {
        let number = pullRequest.number
        noteOpened(.pullRequest(repo: directory.path, number: number))
        guard pullRequestStore != nil else {
            if let url = URL(string: pullRequest.url) { services.platform.open(url) }
            return
        }
        let id = WorktreeReview.id(ofPullRequest: number)
        if !pullRequestReviews.contains(where: { $0.id == id }), let store = pullRequestStore {
            let review = WorktreeReview(
                pullRequest: pullRequest, store: store.directory, services: services)
            review.pullRequests = pullRequests
            review.threads = threads
            review.pullRequestThreads = pullRequestThreads
            review.restore(pullRequestReviewStates[String(number)], override: nil)
            review.fetch = { [weak self] again in
                await self?.fetchListedPullRequests(again: again)
            }
            pullRequestReviews.append(review)
            if let saved = pullRequests?.saved, let repo = pullRequests?.repo {
                Task { [weak self] in await self?.readPullRequestThreads(saved, repo: repo) }
            }
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
            await countChanges(of: listed + opened, in: store.directory)
        } else if again {
            fetchedPullRequests = [:]
        }
        return failure
    }

    /// Listed PRs pushed to since the reader marked one of their files viewed (SPEC §7.2.2).
    package var pullRequestsWithNewCommits: Set<Int> {
        guard let open = pullRequests?.saved.open else { return [] }
        let live = Dictionary(
            pullRequestReviews.compactMap { review in
                review.pullRequest.map {
                    ($0.number, (review.viewedHead, !review.viewed.marks.isEmpty))
                }
            }, uniquingKeysWith: { first, _ in first })
        return Set(
            open.compactMap { pullRequest in
                let state = pullRequestReviewStates[String(pullRequest.number)]
                let (head, hasMarks) =
                    live[pullRequest.number]
                    ?? (state?.viewedHead, !(state?.viewed?.marks.isEmpty ?? true))
                guard hasMarks, let head, head != pullRequest.headCommit else { return nil }
                return pullRequest.number
            })
    }

    /// Six at a time, only for a head or base that moved since it was counted.
    private func countChanges(of pullRequests: [PullRequest], in store: URL) async {
        let git = GitDirectoryClient(services.git, directory: store)
        let wanted = pullRequests.filter {
            countedPullRequests[$0.number] != "\($0.headCommit) \($0.baseCommit)"
        }
        let counted = await withTaskGroup(of: (PullRequest, DiffStat?).self) { group in
            var counted: [(PullRequest, DiffStat?)] = []
            for (index, pullRequest) in wanted.enumerated() {
                if index >= 6, let next = await group.next() { counted.append(next) }
                group.addTask {
                    (
                        pullRequest,
                        try? await DiffStat.between(
                            pullRequest.baseCommit, and: pullRequest.headCommit, in: store,
                            git: git)
                    )
                }
            }
            for await next in group { counted.append(next) }
            return counted
        }
        for (pullRequest, stat) in counted {
            guard let stat else { continue }
            pullRequestTotals[pullRequest.number] = stat
            countedPullRequests[pullRequest.number] =
                "\(pullRequest.headCommit) \(pullRequest.baseCommit)"
        }
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
