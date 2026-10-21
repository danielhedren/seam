import CryptoKit
import DiffView
import Foundation
import GitKit
import Highlighting
import SeamCore
import os

/// What Seam remembers per repo (SPEC §11). Viewed state joins it in M4.
public struct RepoState: Codable, Equatable, Sendable {
    public struct WorktreeState: Codable, Equatable, Sendable {
        public var scope: String?
        public var mode: String?
        public var wraps: Bool?
    }

    /// Base override per branch: the chosen parent ref (SPEC §5.3).
    public var baseOverrides: [String: String] = [:]
    /// Keyed by worktree path.
    public var worktrees: [String: WorktreeState] = [:]

    public init() {}
}

public protocol StateStore: Sendable {
    func load(_ repository: Repository) async -> RepoState
    func save(_ state: RepoState, for repository: Repository) async
    func recentRepositories() async -> [URL]
    func noteOpened(_ directory: URL) async
}

/// JSON files under `~/Library/Application Support/Seam/`. Nothing is written into the repo.
actor JSONStateStore: StateStore {
    private let root: URL
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    init(root: URL = URL.applicationSupportDirectory.appending(path: "Seam")) {
        self.root = root
    }

    func load(_ repository: Repository) -> RepoState {
        read(RepoState.self, from: file(for: repository)) ?? RepoState()
    }

    func save(_ state: RepoState, for repository: Repository) {
        write(state, to: file(for: repository))
    }

    func recentRepositories() -> [URL] {
        (read([String].self, from: root.appending(path: "repos.json")) ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    func noteOpened(_ directory: URL) {
        var paths = recentRepositories().map(\.path).filter { $0 != directory.path }
        paths.insert(directory.path, at: 0)
        write(Array(paths.prefix(10)), to: root.appending(path: "repos.json"))
    }

    /// The common git dir identifies a repo across all of its worktrees.
    private func file(for repository: Repository) -> URL {
        let digest = SHA256.hash(data: Data(repository.commonDirectory.path.utf8))
        let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: id).appending(path: "state.json")
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("unreadable \(url.path, privacy: .public): \(error)")
            return nil
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            logger.error("could not write \(url.path, privacy: .public): \(error)")
        }
    }
}

/// Everything a session talks to, injected so tests and previews use fakes (SPEC §8.2).
public struct SeamServices: Sendable {
    public var git: any GitClient
    public var fileSystem: any FileSystem
    public var watcher: any FileWatcher
    public var clock: any Clock<Duration>
    public var store: any StateStore
    public var detection: DetectionSettings
    /// Shared by every window, so its cache spans repos and reloads.
    public var highlighter: SyntaxHighlighter

    public init(
        git: any GitClient, fileSystem: any FileSystem = LocalFileSystem(),
        watcher: any FileWatcher, clock: any Clock<Duration>, store: any StateStore,
        detection: DetectionSettings = DetectionSettings(),
        highlighter: SyntaxHighlighter = SyntaxHighlighter()
    ) {
        self.highlighter = highlighter
        self.git = git
        self.fileSystem = fileSystem
        self.watcher = watcher
        self.clock = clock
        self.store = store
        self.detection = detection
    }

    public static let live = SeamServices(
        git: CLIGitClient(), watcher: FSEventsWatcher(), clock: ContinuousClock(),
        store: JSONStateStore())
}
