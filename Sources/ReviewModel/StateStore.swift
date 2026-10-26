import DiffModel
import Foundation
import GitKit
import Highlighting
import SeamCore

public protocol StateStore: Sendable {
    /// An empty state when there's none or it can't be read; `loadProblem` says which.
    func load(_ repository: Repository) async -> RepoState
    /// Why the last load fell back to an empty state, for the window to say (SPEC §11).
    func loadProblem(for repository: Repository) async -> String?
    /// Nil when it saved, else why not.
    @discardableResult
    func save(_ state: RepoState, for repository: Repository) async -> String?
    /// Keeps the text a file had when it was marked viewed, by its content id, so a later change
    /// can be shown as the change since then (SPEC §11).
    func keepSeen(_ text: String, id: String, for repository: Repository) async
    func seen(_ id: String, for repository: Repository) async -> String?
    func recentRepositories() async -> [URL]
    func noteOpened(_ directory: URL) async
    func clearRecent() async
}

/// JSON files under `~/Library/Application Support/Seam/`. Nothing is written into the repo.
package actor JSONStateStore: StateStore {
    private let root: URL
    private var loadProblems: [String: String] = [:]
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    package init(root: URL = AppChoices.stateRoot) {
        self.root = root
    }

    /// A file that won't decode is moved aside rather than overwritten by the next save, so
    /// the reader's viewed marks and bases can still be recovered by hand.
    package func load(_ repository: Repository) -> RepoState {
        let url = file(for: repository)
        loadProblems[url.path] = nil
        guard let data = try? Data(contentsOf: url) else { return RepoState() }
        do {
            let state = try JSONDecoder().decode(RepoState.self, from: data)
            pruneSeen(keeping: state, for: repository)
            return state
        } catch {
            logger.error("unreadable \(url.path, privacy: .public): \(error)")
            let kept = url.deletingLastPathComponent().appending(path: "state.json.unreadable")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: url, to: kept)
            loadProblems[url.path] = String(
                localized:
                    "Seam couldn't read what it saved for this repository, so viewed files and chosen bases start afresh. The old file is kept as \(kept.path).",
                bundle: .module)
            return RepoState()
        }
    }

    package func loadProblem(for repository: Repository) -> String? {
        loadProblems[file(for: repository).path]
    }

    @discardableResult
    package func save(_ state: RepoState, for repository: Repository) -> String? {
        write(state, to: file(for: repository))
    }

    package func keepSeen(_ text: String, id: String, for repository: Repository) {
        let url = seenDirectory(for: repository).appending(path: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            logger.error("could not write \(url.path, privacy: .public): \(error)")
        }
    }

    package func seen(_ id: String, for repository: Repository) -> String? {
        (try? Data(contentsOf: seenDirectory(for: repository).appending(path: id)))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Only on load: a save can race a mark that was just kept, and nothing else drops marks.
    private func pruneSeen(keeping state: RepoState, for repository: Repository) {
        let directory = seenDirectory(for: repository)
        let marked = Set(
            state.worktrees.values.flatMap { $0.viewed.map { Array($0.marks.values) } ?? [] })
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in kept where !marked.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private func seenDirectory(for repository: Repository) -> URL {
        file(for: repository).deletingLastPathComponent().appending(path: "viewed")
    }

    package func recentRepositories() -> [URL] {
        (read([String].self, from: root.appending(path: "repos.json")) ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    package func clearRecent() {
        write([String](), to: root.appending(path: "repos.json"))
    }

    package func noteOpened(_ directory: URL) {
        var paths = recentRepositories().map(\.path).filter { $0 != directory.path }
        paths.insert(directory.path, at: 0)
        write(Array(paths.prefix(10)), to: root.appending(path: "repos.json"))
    }

    private func file(for repository: Repository) -> URL {
        AppChoices.stateFile(for: repository, in: root)
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

    @discardableResult
    private func write<Value: Encodable>(_ value: Value, to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            return nil
        } catch {
            logger.error("could not write \(url.path, privacy: .public): \(error)")
            return String(
                localized: "Seam couldn't save its state: \(error.localizedDescription)",
                bundle: .module)
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
    public var settings: AppSettings
    /// Shared by every window, so its cache spans repos and reloads.
    public var highlighter: SyntaxHighlighter
    /// Review threads, shared with the `seam` command (SPEC §7.7).
    public var threads: ThreadStore
    /// The recent repositories, for Spotlight to find.
    public var spotlight: any RepoIndex
    /// Pull requests through gh (SPEC §7.8); tests get one that never runs anything.
    public var github: GitHubAccount
    /// The pasteboard, browser and file manager.
    public var platform: any PlatformServices
    var launcher: any CommandLauncher = ShellLauncher()

    @MainActor
    public init(
        git: any GitClient, fileSystem: any FileSystem = LocalFileSystem(),
        watcher: any FileWatcher, clock: any Clock<Duration>, store: any StateStore,
        threads: ThreadStore, settings: AppSettings,
        highlighter: SyntaxHighlighter = SyntaxHighlighter(),
        spotlight: any RepoIndex = NoRepoIndex(), github: GitHubAccount = .none(),
        platform: any PlatformServices = NoPlatform()
    ) {
        self.platform = platform
        self.github = github
        self.threads = threads
        self.spotlight = spotlight
        self.highlighter = highlighter
        self.git = git
        self.fileSystem = fileSystem
        self.watcher = watcher
        self.clock = clock
        self.store = store
        self.settings = settings
    }
}
