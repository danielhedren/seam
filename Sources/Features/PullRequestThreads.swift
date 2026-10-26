import Foundation
import GitKit
import Observation
import SeamCore

/// A repo's pull request review threads (SPEC §7.9): which worktrees' to read and when, the
/// GitHub file `seam` reads them from, and what's in memory. `RepoPullRequests` hands it each
/// read of the PRs; Seam's own threads are `RepoThreads`'.
@MainActor
@Observable
final class PullRequestThreads {
    private(set) var threads: [ReviewThread] = []
    /// Bumped when the threads change, so placements are worked out again only then.
    private(set) var version = 0
    /// Settings can turn pull requests, and with them their threads, off.
    @ObservationIgnored var isShown: @MainActor () -> Bool = { true }

    /// Read again after this long even when the PR's update time hasn't moved: resolving a
    /// thread may not change it.
    static let rereadAfter = Duration.seconds(600)

    private let repository: Repository
    private let store: ThreadStoreAccess
    private let client: any GitHubClient
    private let clock: any Clock<Duration>
    /// The PR each worktree's threads were last read for, as it was then.
    private var read: [String: (pullRequest: PullRequest, age: Stopwatch)] = [:]
    private var watchTask: Task<Void, Never>?
    private var isStopped = false
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    init(
        repository: Repository, store: ThreadStore, client: any GitHubClient,
        clock: any Clock<Duration>
    ) {
        self.repository = repository
        self.store = ThreadStoreAccess(store)
        self.client = client
        self.clock = clock
    }

    func threads(in worktree: String) -> [ReviewThread] {
        isShown() ? threads.filter { $0.worktree == worktree } : []
    }

    /// Shows what the file holds, and again whenever another window writes it.
    func start(watching watcher: any FileWatcher) async {
        let file = store.store.gitHubFile(for: repository).lastPathComponent
        let events = watcher.events(for: [store.store.directory])
        watchTask = Task { [weak self] in
            for await paths in events where paths.contains(where: { $0.hasSuffix(file) }) {
                await self?.load()
            }
        }
        await load()
    }

    func stop() {
        isStopped = true
        watchTask?.cancel()
        watchTask = nil
    }

    /// Reload reads every worktree's threads again.
    func forgetReads() {
        read = [:]
    }

    /// Pull requests were switched off: nothing is kept, here or in the file.
    func clearAll() async {
        read = [:]
        await keep(only: [])
    }

    /// Brings the threads in line with a read of the PRs: every worktree's PR's threads are read
    /// when the PR changed or 10 minutes passed; worktrees without one, and gone ones, lose theirs.
    func reconcile(
        _ saved: SavedPullRequests, repo: GitHubRepo, worktrees: [String: String?]
    ) async {
        await keep(only: Set(worktrees.keys))
        var jobs: [(worktree: String, pullRequest: PullRequest)] = []
        for (worktree, branch) in worktrees.sorted(by: { $0.key < $1.key }) {
            guard let branch, let pullRequest = saved.byBranch[branch] else {
                read[worktree] = nil
                await save([], worktree: worktree)
                continue
            }
            if let last = read[worktree], last.pullRequest.number == pullRequest.number,
                last.pullRequest.updated == pullRequest.updated,
                last.age.elapsed < Self.rereadAfter
            {
                continue
            }
            jobs.append((worktree, pullRequest))
        }
        // Two worktrees on one branch share its PR, which is read once.
        let client = client
        let numbers = Array(Set(jobs.map(\.pullRequest.number)))
        let answers = Dictionary(
            (try? await RepoPullRequests.concurrently(numbers) { number in
                await Result { () async throws(GitHubError) in
                    try await client.reviewThreads(number, in: repo)
                }
            }) ?? [], uniquingKeysWith: { first, _ in first })
        for job in jobs {
            guard !isStopped, let answer = answers[job.pullRequest.number] else { continue }
            switch answer {
            case .success(let threads):
                read[job.worktree] = (job.pullRequest, Stopwatch(clock))
                await save(
                    GitHubThreads.threads(
                        from: threads, worktree: job.worktree, repo: repo,
                        pullRequest: job.pullRequest.number),
                    worktree: job.worktree)
            case .failure(let error):
                logger.info("review threads unread: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func load() async {
        guard let saved = try? await store.gitHubThreads(for: repository).threads else { return }
        show(saved)
    }

    /// Replaces a worktree's threads with a new read, kept for `seam` too.
    private func save(_ new: [ReviewThread], worktree: String) async {
        guard !(new.isEmpty && !threads.contains(where: { $0.worktree == worktree })) else {
            return
        }
        let result = await Result { () async throws(ThreadError) in
            try await store.saveGitHubThreads(new, worktree: worktree, read: .now, for: repository)
        }
        switch result {
        case .success(let stored): show(threads.filter { $0.worktree != worktree } + stored)
        case .failure(let error):
            logger.error("pull request threads: \(String(describing: error), privacy: .public)")
        }
    }

    private func keep(only worktrees: Set<String>) async {
        let result = await Result { () async throws(ThreadError) in
            try await store.pruneGitHubThreads(keeping: worktrees, for: repository)
        }
        switch result {
        case .success(let kept): show(kept)
        case .failure(let error):
            logger.error("pull request threads: \(String(describing: error), privacy: .public)")
        }
    }

    private func show(_ new: [ReviewThread]) {
        guard new != threads else { return }
        threads = new
        version += 1
    }
}
