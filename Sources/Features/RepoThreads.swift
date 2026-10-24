import Foundation
import GitKit
import Observation
import SeamCore
import os

/// A repo's review threads (SPEC §7.7), from the store the `seam` command shares, reloaded
/// whenever another process changes it so agents' replies appear live. Store I/O runs off the
/// main actor: a change waits on the store's lock.
@MainActor
@Observable
final class RepoThreads {
    private(set) var threads: [ReviewThread] = []
    /// Pull request threads (SPEC §7.9), as last read; read-only.
    private(set) var gitHub: [ReviewThread] = []
    /// Settings can turn pull requests, and with them their threads, off.
    @ObservationIgnored var showsGitHub: @MainActor () -> Bool = { true }
    /// Bumped when the threads change, so placements are worked out again only then.
    private(set) var version = 0
    private(set) var failure: String?

    private let repository: Repository
    private let store: ThreadStore
    private let git: any GitClient
    /// The reader's git email per worktree, which signs what they write.
    private var readers: [String: ReviewerIdentity] = [:]
    private var watchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    init(repository: Repository, store: ThreadStore, git: any GitClient) {
        self.repository = repository
        self.store = store
        self.git = git
    }

    /// The worktree's `user.email`, so a comment says who wrote it wherever it's read; "you"
    /// when git has none.
    func reader(in worktree: String) async -> ReviewerIdentity {
        if let known = readers[worktree] { return known }
        let email = try? await git.string(
            ["config", "--get", "user.email"], in: URL(fileURLWithPath: worktree))
        let name = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reader = ReviewerIdentity(name: name.isEmpty ? ReviewThread.reader : name)
        readers[worktree] = reader
        return reader
    }

    func start(watching watcher: any FileWatcher) async {
        try? FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true)
        let file = store.file(for: repository).lastPathComponent
        let events = watcher.events(for: [store.directory])
        watchTask = Task { [weak self] in
            for await paths in events where paths.contains(where: { $0.hasSuffix(file) }) {
                await self?.load()
            }
        }
        await load()
        let (store, repository) = (store, repository)
        if let saved = await Task.detached(operation: {
            try? store.gitHubThreads(for: repository).threads
        }).value, saved != gitHub {
            gitHub = saved
            version += 1
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    func load() async {
        let (store, repository) = (store, repository)
        let result = await Task.detached {
            Result { () throws(ThreadError) in try store.threads(for: repository) }
        }.value
        apply(result.map { _ in () }, threads: try? result.get())
    }

    func dismissFailure() {
        failure = nil
    }

    func threads(in worktree: String) -> [ReviewThread] {
        threads.filter { $0.worktree == worktree }
            + (showsGitHub() ? gitHub.filter { $0.worktree == worktree } : [])
    }

    /// Forgets the pull request threads of worktrees not in `worktrees`, in the file too.
    func keepGitHub(only worktrees: Set<String>) async {
        let (store, repository) = (store, repository)
        let result = await Task.detached {
            Result { () throws(ThreadError) in
                try store.pruneGitHubThreads(keeping: worktrees, for: repository)
            }
        }.value
        switch result {
        case .success(let kept):
            if kept != gitHub {
                gitHub = kept
                version += 1
            }
        case .failure(let error):
            logger.error("pull request threads: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces a worktree's pull request threads with a new read, kept for `seam` too.
    func saveGitHub(_ read: [ReviewThread], worktree: String) async {
        let current = gitHub.filter { $0.worktree == worktree }
        guard !(read.isEmpty && current.isEmpty) else { return }
        let (store, repository) = (store, repository)
        let result = await Task.detached {
            Result { () throws(ThreadError) in
                try store.saveGitHubThreads(read, worktree: worktree, read: .now, for: repository)
            }
        }.value
        switch result {
        case .success(let stored):
            let updated = gitHub.filter { $0.worktree != worktree } + stored
            if updated != gitHub {
                gitHub = updated
                version += 1
            }
        case .failure(let error):
            logger.error("pull request threads: \(String(describing: error), privacy: .public)")
        }
    }

    /// Nil, with `failure` set, when the store refused it.
    @discardableResult
    func open(worktree: String, anchor: ThreadAnchor, body: String) async -> ReviewThread? {
        let author = await reader(in: worktree).name
        let origin = await ThreadOrigin.find(
            path: anchor.path, in: URL(fileURLWithPath: worktree), git: git)
        return await change { threads throws(ThreadError) in
            try ThreadRules.open(
                &threads, worktree: worktree, anchor: anchor, author: author, body: body,
                now: .now, origin: origin)
        }
    }

    @discardableResult
    func reply(to id: String, body: String) async -> Bool {
        var reader = ReviewThread.reader
        if let worktree = threads.first(where: { $0.id == id })?.worktree {
            reader = await self.reader(in: worktree).name
        }
        let author = reader
        return await change { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: id, author: author, body: body, now: .now)
        } != nil
    }

    @discardableResult
    func setResolved(_ resolved: Bool, id: String) async -> Bool {
        await change { threads throws(ThreadError) in
            try ThreadRules.setResolved(resolved, &threads, id: id, now: .now)
        } != nil
    }

    func delete(id: String) async -> (thread: ReviewThread, index: Int)? {
        await change { threads throws(ThreadError) in try ThreadRules.delete(&threads, id: id) }
    }

    func restore(_ thread: ReviewThread, at index: Int) async {
        await change { threads in ThreadRules.restore(thread, at: index, in: &threads) }
    }

    private func change<Value: Sendable>(
        _ body: @escaping @Sendable (inout [ReviewThread]) throws(ThreadError) -> Value
    ) async -> Value? {
        let (store, repository) = (store, repository)
        let result = await Task.detached {
            Result { () throws(ThreadError) -> (Value, [ReviewThread]) in
                try store.update(repository) { threads throws(ThreadError) in
                    (try body(&threads), threads)
                }
            }
        }.value
        apply(result.map { _ in () }, threads: try? result.get().1)
        return try? result.get().0
    }

    private func apply(_ outcome: Result<Void, ThreadError>, threads: [ReviewThread]?) {
        switch outcome {
        case .success:
            if let threads, threads != self.threads {
                self.threads = threads
                version += 1
            }
            if failure != nil { failure = nil }
        case .failure(let error):
            logger.error("threads: \(String(describing: error), privacy: .public)")
            failure = Self.describe(error)
        }
    }

    static func describe(_ error: ThreadError) -> String {
        switch error {
        case .unknownThread(let id):
            String(localized: "Thread #\(id) no longer exists.", bundle: .module)
        case .emptyComment: String(localized: "Write something first.", bundle: .module)
        case .unsupportedVersion:
            String(
                localized:
                    "These threads were saved by a newer version of Seam. Update Seam to change them.",
                bundle: .module)
        case .unreadable(let message):
            String(localized: "Couldn't read the threads: \(message)", bundle: .module)
        case .unwritable(let message):
            String(localized: "Couldn't save the threads: \(message)", bundle: .module)
        }
    }
}
