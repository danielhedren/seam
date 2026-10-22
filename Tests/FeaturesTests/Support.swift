import Foundation
import GitKit
import SeamCore
import Synchronization
import TestSupport

@testable import Features

actor MemoryStore: StateStore {
    var states: [String: RepoState] = [:]
    var opened: [URL] = []

    func load(_ repository: Repository) -> RepoState {
        states[repository.commonDirectory.path] ?? RepoState()
    }

    func save(_ state: RepoState, for repository: Repository) {
        states[repository.commonDirectory.path] = state
    }

    func recentRepositories() -> [URL] { opened }
    func noteOpened(_ directory: URL) { opened.append(directory) }
    func clearRecent() { opened = [] }
}

/// Never reports changes; tests deliver `RepoChange`s directly.
struct SilentWatcher: FileWatcher {
    func events(for directories: [URL]) -> AsyncStream<[String]> {
        AsyncStream { _ in }
    }
}

/// Reports exactly the changes a test sends.
final class ManualWatcher: FileWatcher, Sendable {
    private let continuations = Mutex<[AsyncStream<[String]>.Continuation]>([])

    func events(for directories: [URL]) -> AsyncStream<[String]> {
        AsyncStream { continuation in continuations.withLock { $0.append(continuation) } }
    }

    func send(_ paths: [String]) {
        for continuation in continuations.withLock({ $0 }) { continuation.yield(paths) }
    }
}

/// Holds one git command (`diff` by default) in one worktree until released, to observe work in
/// flight.
final class GatedGit: GitClient, Sendable {
    private struct State {
        var open = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        var held = 0
    }

    private let inner: any GitClient
    private let gated: String
    private let command: String
    private let state = Mutex(State())

    init(_ inner: any GitClient, holding worktree: URL, command: String = "diff") {
        self.inner = inner
        gated = worktree.path
        self.command = command
    }

    var heldCount: Int { state.withLock { $0.held } }

    func release() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return state.waiters.values
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Holds the command again from here on.
    func close() {
        state.withLock { $0.open = false }
    }

    private func hold() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                state.held += 1
                if !state.open { state.waiters[id] = continuation }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError) -> Data
    {
        // A row's totals are a `diff --shortstat`; holding those would stall every row refresh.
        if arguments.first == command, !arguments.contains("--shortstat"), directory.path == gated {
            await hold()
        }
        // Detached, so a cancelled caller still gets a result: the session alone must discard it.
        let inner = inner
        let result = await Task.detached {
            await Result { () async throws(GitError) -> Data in
                try await inner.run(arguments, in: directory, input: input)
            }
        }.value
        return try result.get()
    }
}

@MainActor
func services(
    _ git: any GitClient, clock: any Clock<Duration> = ManualClock(),
    store: any StateStore = MemoryStore()
) -> SeamServices {
    SeamServices(
        git: git, watcher: SilentWatcher(), clock: clock, store: store,
        threads: scratchThreadStore(), settings: testSettings())
}

/// Never the real store: that holds the reader's threads.
func scratchThreadStore() -> ThreadStore {
    ThreadStore(
        directory: FileManager.default.temporaryDirectory.appending(
            path: "seam-threads-\(UUID().uuidString)", directoryHint: .isDirectory))
}

/// Records launched command lines; `next()` waits for the next one.
actor FakeLauncher: CommandLauncher {
    private var lines: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []
    var failure: String?

    func fail(with message: String) { failure = message }

    func run(_ commandLine: String) throws {
        if waiters.isEmpty {
            lines.append(commandLine)
        } else {
            waiters.removeFirst().resume(returning: commandLine)
        }
        if let failure { throw LaunchFailed(message: failure) }
    }

    func next() async -> String {
        if !lines.isEmpty { return lines.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// Settings in a throwaway defaults domain, so tests never read or write the user's.
@MainActor
func testSettings() -> AppSettings {
    AppSettings(defaults: UserDefaults(suiteName: "seam-tests-\(UUID())") ?? UserDefaults())
}

/// Set from a task the test starts, so it knows that task has begun.
@MainActor
final class Flag {
    var isSet = false
}

/// Never reports changes, and runs `onFirstWatch` when the first watch starts.
final class FirstWatchWatcher: FileWatcher, Sendable {
    private let pending = Mutex<(@MainActor @Sendable () -> Void)?>(nil)

    func onFirstWatch(_ action: @escaping @MainActor @Sendable () -> Void) {
        pending.withLock { $0 = action }
    }

    func events(for directories: [URL]) -> AsyncStream<[String]> {
        if let action = pending.withLock({ $0.take() }) {
            MainActor.assumeIsolated { action() }
        }
        return AsyncStream { _ in }
    }
}
