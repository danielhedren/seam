import Foundation
import GitKit
import Observation
import SeamCore
import os

/// A repo's review threads (SPEC §7.7), from the store the `seam` command shares, reloaded
/// whenever another process changes it so agents' replies appear live. Store I/O runs in order
/// off the main actor, and a read that finishes after a newer one is dropped.
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
    private let store: ThreadStoreAccess
    private let git: any GitClient
    /// Reads and writes in the order they began; `applied` is the newest one shown.
    private var issued = 0
    private var applied = 0
    /// The reader's git email per worktree, which signs what they write.
    private var readers: [String: ReviewerIdentity] = [:]
    private var watchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    init(repository: Repository, store: ThreadStore, git: any GitClient) {
        self.repository = repository
        self.store = ThreadStoreAccess(store)
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
        let directory = store.store.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = store.store.file(for: repository).lastPathComponent
        let events = watcher.events(for: [directory])
        watchTask = Task { [weak self] in
            for await paths in events where paths.contains(where: { $0.hasSuffix(file) }) {
                await self?.load()
            }
        }
        await load()
        if let saved = try? await store.gitHubThreads(for: repository).threads, saved != gitHub {
            gitHub = saved
            version += 1
        }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    func load() async {
        let ticket = nextTicket()
        let result = await Result { () async throws(ThreadError) in
            try await store.threads(for: repository)
        }
        apply(result.map { _ in () }, threads: try? result.get(), ticket: ticket)
    }

    private func nextTicket() -> Int {
        issued += 1
        return issued
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
        let result = await Result { () async throws(ThreadError) in
            try await store.pruneGitHubThreads(keeping: worktrees, for: repository)
        }
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
        let result = await Result { () async throws(ThreadError) in
            try await store.saveGitHubThreads(
                read, worktree: worktree, read: .now, for: repository)
        }
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
        let ticket = nextTicket()
        let result = await Result { () async throws(ThreadError) in
            try await store.update(repository, body)
        }
        apply(result.map { _ in () }, threads: try? result.get().1, ticket: ticket)
        return try? result.get().0
    }

    private func apply(
        _ outcome: Result<Void, ThreadError>, threads: [ReviewThread]?, ticket: Int
    ) {
        switch outcome {
        case .success:
            guard ticket > applied else { return }
            applied = ticket
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
