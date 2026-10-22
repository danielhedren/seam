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
    /// Whether cancelling a held call ends it, as terminating a real git process does.
    private let cancellable: Bool
    private let state = Mutex(State())
    private let heldWaiters = Mutex<[CheckedContinuation<Void, Never>]>([])

    init(
        _ inner: any GitClient, holding worktree: URL, command: String = "diff",
        cancellable: Bool = false
    ) {
        self.inner = inner
        gated = worktree.path
        self.command = command
        self.cancellable = cancellable
    }

    var heldCount: Int { state.withLock { $0.held } }

    /// Returns once a call is being held.
    func held() async {
        await withCheckedContinuation { continuation in
            heldWaiters.withLock { $0.append(continuation) }
            if state.withLock({ $0.held > 0 }) { resumeHeldWaiters() }
        }
    }

    private func resumeHeldWaiters() {
        let waiters = heldWaiters.withLock { waiters in
            defer { waiters = [] }
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func release() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return state.waiters.values
        }
        for waiter in waiters { waiter.resume() }
    }

    private func hold() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    state.held += 1
                    if !state.open { state.waiters[id] = continuation }
                    return state.open
                }
                resumeHeldWaiters()
                if open { continuation.resume() }
            }
        } onCancel: {
            guard cancellable else { return }
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError) -> Data
    {
        if arguments.first == command, directory.path == gated {
            await hold()
            if cancellable, Task.isCancelled { throw .cancelled }
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
        settings: testSettings())
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
