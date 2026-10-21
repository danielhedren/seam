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
}

/// Never reports changes; tests deliver `RepoChange`s directly.
struct SilentWatcher: FileWatcher {
    func events(for directories: [URL]) -> AsyncStream<[String]> {
        AsyncStream { _ in }
    }
}

/// Holds `git diff` in one worktree until released, to observe work in flight.
final class GatedGit: GitClient, Sendable {
    private let inner: any GitClient
    private let gated: String
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>], held: Int)>(
        (false, [], 0))

    init(_ inner: any GitClient, holding worktree: URL) {
        self.inner = inner
        gated = worktree.path
    }

    var heldCount: Int { state.withLock { $0.held } }

    func release() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError) -> Data
    {
        if arguments.first == "diff", directory.path == gated {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    state.held += 1
                    if !state.open { state.waiters.append(continuation) }
                    return state.open
                }
                if open { continuation.resume() }
            }
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
    SeamServices(git: git, watcher: SilentWatcher(), clock: clock, store: store)
}
