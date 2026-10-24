import Foundation

/// The app's way into the thread store: one at a time, in order, off the main actor. The store
/// itself stays synchronous for `seam`, and `flock` keeps processes apart.
public actor ThreadStoreAccess {
    public nonisolated let store: ThreadStore

    public init(_ store: ThreadStore) {
        self.store = store
    }

    public func threads(for repository: Repository) throws(ThreadError) -> [ReviewThread] {
        try store.threads(for: repository)
    }

    /// The change's result with the threads as written.
    public func update<Value: Sendable>(
        _ repository: Repository,
        _ change: @Sendable (inout [ReviewThread]) throws(ThreadError) -> Value
    ) throws(ThreadError) -> (Value, [ReviewThread]) {
        try store.update(repository) { threads throws(ThreadError) in
            (try change(&threads), threads)
        }
    }

    public func gitHubThreads(for repository: Repository) throws(ThreadError) -> GitHubThreadFile {
        try store.gitHubThreads(for: repository)
    }

    public func saveGitHubThreads(
        _ threads: [ReviewThread], worktree: String, read: Date, for repository: Repository
    ) throws(ThreadError) -> [ReviewThread] {
        try store.saveGitHubThreads(threads, worktree: worktree, read: read, for: repository)
    }

    public func pruneGitHubThreads(keeping worktrees: Set<String>, for repository: Repository)
        throws(ThreadError) -> [ReviewThread]
    {
        try store.pruneGitHubThreads(keeping: worktrees, for: repository)
    }
}
