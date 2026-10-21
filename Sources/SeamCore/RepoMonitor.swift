import Foundation
import GitKit
import os

/// What a batch of file events means for the repo (SPEC §8.6).
public struct RepoChange: Equatable, Sendable {
    /// Ids of worktrees whose files or index changed.
    public var worktrees: Set<String> = []
    /// Refs, HEADs or the worktree list changed: re-run base detection everywhere.
    public var refs = false

    public init(worktrees: Set<String> = [], refs: Bool = false) {
        self.worktrees = worktrees
        self.refs = refs
    }

    public var isEmpty: Bool { worktrees.isEmpty && !refs }

    mutating func merge(_ other: RepoChange) {
        worktrees.formUnion(other.worktrees)
        refs = refs || other.refs
    }
}

/// Maps raw paths to worktrees and git-dir changes. Pure, so the routing rules are unit tested.
struct ChangeClassifier {
    struct Result: Equatable {
        var change = RepoChange()
        /// Working-tree paths, relative to their worktree, that still need the ignore check.
        var files: [String: [String]] = [:]
    }

    private let common: String
    /// Longest root first, so a worktree nested inside another one claims its own paths.
    private let roots: [(root: String, id: String)]
    private let adminDirectories: [String: String]

    init(repository: Repository, worktrees: [Worktree]) {
        common = Self.directory(repository.commonDirectory)
        roots = worktrees.map { (Self.directory($0.path), $0.id) }
            .sorted { $0.root.count > $1.root.count }
        adminDirectories = Dictionary(
            worktrees.compactMap { worktree in
                worktree.gitDirectory.map { (Self.directory($0), worktree.id) }
            }, uniquingKeysWith: { first, _ in first })
    }

    /// The directories to watch: every worktree root and the common dir, minus nested ones.
    var watchedDirectories: [URL] {
        let all = (roots.map(\.root) + [common]).sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in all where !kept.contains(where: { path.hasPrefix($0) }) {
            kept.append(path)
        }
        return kept.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func classify(_ paths: [String]) -> Result {
        var result = Result()
        for path in paths {
            if (path + "/").hasPrefix(common) {
                classifyGitPath(String(path.dropFirst(min(common.count, path.count))), &result)
                continue
            }
            guard let match = roots.first(where: { (path + "/").hasPrefix($0.root) }) else {
                continue
            }
            let relative = String(path.dropFirst(min(match.root.count, path.count)))
            if relative == ".git" || relative.hasPrefix(".git/") { continue }
            result.files[match.id, default: []].append(relative.isEmpty ? "." : relative)
        }
        return result
    }

    private func classifyGitPath(_ relative: String, _ result: inout Result) {
        if relative.hasSuffix(".lock") { return }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        switch parts.first {
        case nil, "HEAD", "packed-refs", "refs":
            result.change.refs = true
        case "index":
            if let id = adminDirectories[common] { result.change.worktrees.insert(id) }
        case "worktrees" where parts.count <= 2 || parts.last == "HEAD":
            result.change.refs = true
        case "worktrees" where parts.count == 3 && parts[2] == "index":
            let admin = common + "worktrees/\(parts[1])/"
            if let id = adminDirectories[admin] { result.change.worktrees.insert(id) }
        default:
            break
        }
    }

    /// Not standardised: that strips `/private`, while FSEvents and git report real paths.
    private static func directory(_ url: URL) -> String {
        let path = url.path
        return path.hasSuffix("/") ? path : path + "/"
    }
}

/// Watches every worktree and the common git dir; emits coalesced changes. The first relevant
/// event opens a window, and everything arriving within it is delivered together.
public actor RepoMonitor {
    private let classifier: ChangeClassifier
    private let watcher: any FileWatcher
    private let git: any GitClient
    private let clock: any Clock<Duration>
    private let window: Duration
    private let worktreePaths: [String: URL]
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "SeamCore")

    private var pending = RepoChange()
    private var flush: Task<Void, Never>?

    public init(
        repository: Repository, worktrees: [Worktree], watcher: any FileWatcher,
        git: any GitClient, clock: any Clock<Duration>, window: Duration = .milliseconds(300)
    ) {
        classifier = ChangeClassifier(repository: repository, worktrees: worktrees)
        worktreePaths = Dictionary(
            worktrees.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        self.watcher = watcher
        self.git = git
        self.clock = clock
        self.window = window
    }

    /// Watching starts before this returns, so a write right after it is seen.
    public nonisolated func changes() -> AsyncStream<RepoChange> {
        let events = watcher.events(for: classifier.watchedDirectories)
        return AsyncStream { continuation in
            let task = Task { await self.run(events, continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ events: AsyncStream<[String]>, _ continuation: AsyncStream<RepoChange>.Continuation
    ) async {
        for await paths in events {
            let change = await relevantChange(paths)
            guard !change.isEmpty else { continue }
            pending.merge(change)
            guard flush == nil else { continue }
            flush = Task {
                try? await clock.sleep(for: window)
                deliver(continuation)
            }
        }
        flush?.cancel()
        continuation.finish()
    }

    private func deliver(_ continuation: AsyncStream<RepoChange>.Continuation) {
        flush = nil
        guard !Task.isCancelled else { return }
        continuation.yield(pending)
        pending = RepoChange()
    }

    /// Drops paths git ignores before they reach the window, so build churn costs no reloads.
    private func relevantChange(_ paths: [String]) async -> RepoChange {
        let result = classifier.classify(paths)
        var change = result.change
        // Worktrees already due to reload skip the ignore check: during a build every batch
        // would otherwise cost one git process per worktree.
        for (id, files) in result.files
        where !change.worktrees.contains(id) && !pending.worktrees.contains(id) {
            guard let root = worktreePaths[id] else { continue }
            if await hasUnignoredPath(files, in: root) { change.worktrees.insert(id) }
        }
        return change
    }

    private func hasUnignoredPath(_ files: [String], in root: URL) async -> Bool {
        let unique = Set(files)
        let input = Data(unique.joined(separator: "\0").utf8) + Data([0])
        do {
            let output = try await git.run(
                ["check-ignore", "--stdin", "-z"], in: root, input: input)
            return output.split(separator: 0).count < unique.count
        } catch {
            // Exit 1 means nothing was ignored; anything else, assume the change matters.
            if case .nonZeroExit(_, let status, _) = error, status != 1 {
                logger.error("check-ignore failed in \(root.path, privacy: .public): \(error)")
            }
            return true
        }
    }
}
