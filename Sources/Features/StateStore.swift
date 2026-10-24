import AppKit
import DiffView
import Foundation
import GitKit
import Highlighting
import SeamCore
import os

public protocol StateStore: Sendable {
    func load(_ repository: Repository) async -> RepoState
    func save(_ state: RepoState, for repository: Repository) async
    func recentRepositories() async -> [URL]
    func noteOpened(_ directory: URL) async
    func clearRecent() async
}

/// JSON files under `~/Library/Application Support/Seam/`. Nothing is written into the repo.
actor JSONStateStore: StateStore {
    private let root: URL
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")

    init(root: URL = AppChoices.stateRoot) {
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

    func clearRecent() {
        write([String](), to: root.appending(path: "repos.json"))
    }

    func noteOpened(_ directory: URL) {
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
    public var settings: AppSettings
    /// Shared by every window, so its cache spans repos and reloads.
    public var highlighter: SyntaxHighlighter
    /// Review threads, shared with the `seam` command (SPEC §7.7).
    public var threads: ThreadStore
    /// The recent repositories, for Spotlight to find.
    public var spotlight: any RepoIndex
    /// Pull requests through gh (SPEC §7.8); tests get one that never runs anything.
    public var github: GitHubAccount
    var launcher: any CommandLauncher = ShellLauncher()
    var openURL: @MainActor @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) }

    @MainActor
    public init(
        git: any GitClient, fileSystem: any FileSystem = LocalFileSystem(),
        watcher: any FileWatcher, clock: any Clock<Duration>, store: any StateStore,
        threads: ThreadStore, settings: AppSettings,
        highlighter: SyntaxHighlighter = SyntaxHighlighter(),
        spotlight: any RepoIndex = NoRepoIndex(), github: GitHubAccount = .none()
    ) {
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

    @MainActor
    public static func live() -> SeamServices {
        SeamServices(
            git: CLIGitClient(), watcher: FSEventsWatcher(), clock: ContinuousClock(),
            store: JSONStateStore(), threads: ThreadStore(), settings: AppSettings(),
            spotlight: SpotlightRepoIndex(), github: .live())
    }
}
