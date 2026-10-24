import AppKit
import DiffView
import Foundation
import GitKit
import SeamCore
import SwiftUI
import Synchronization
import TestSupport
import Testing

@testable import Features

actor MemoryStore: StateStore {
    var states: [String: RepoState] = [:]
    var opened: [URL] = []
    private(set) var saves = 0

    func load(_ repository: Repository) -> RepoState {
        states[repository.commonDirectory.path] ?? RepoState()
    }

    @discardableResult
    func save(_ state: RepoState, for repository: Repository) -> String? {
        states[repository.commonDirectory.path] = state
        saves += 1
        return nil
    }

    func loadProblem(for repository: Repository) -> String? { nil }

    func seed(_ state: RepoState, for repository: Repository) {
        states[repository.commonDirectory.path] = state
    }

    var seenTexts: [String: String] = [:]
    func keepSeen(_ text: String, id: String, for repository: Repository) { seenTexts[id] = text }
    func seen(_ id: String, for repository: Repository) -> String? { seenTexts[id] }
    func forgetSeen() { seenTexts = [:] }

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

    /// A cancelled hold lets go, so a test that never releases fails at its time limit.
    private func hold() async {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let open = state.withLock { state in
                    state.held += 1
                    if !state.open, !Task.isCancelled { state.waiters[id] = continuation }
                    return state.open || Task.isCancelled
                }
                if open { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
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
    store: any StateStore = MemoryStore(), watcher: any FileWatcher = SilentWatcher(),
    threads: ThreadStore = scratchThreadStore(), github: GitHubAccount = .none()
) -> SeamServices {
    SeamServices(
        git: ReadOnlyGit(git), watcher: watcher, clock: clock, store: store, threads: threads,
        settings: testSettings(), github: github)
}

/// Never the real store: that holds the reader's threads.
func scratchThreadStore() -> ThreadStore {
    ThreadStore(directory: Scratch.path("seam-threads"))
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
    AppSettings(defaults: Scratch.defaults("seam-tests"))
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

/// A diff view showing the selected worktree's diff, wired to the session as the window does.
@MainActor
@discardableResult
func showDiff(_ session: RepoSession) throws -> DiffScrollView {
    let view = DiffScrollView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    session.diff.view = view
    view.show(try #require(session.selected?.content), position: .top)
    return view
}

/// Seam never writes to the repository, the index or `.git` (AGENTS.md): every git command the
/// session runs must be one of these reads, or the test fails naming it.
struct ReadOnlyGit: GitClient {
    let inner: any GitClient

    init(_ inner: any GitClient) {
        self.inner = inner
    }

    private static let reads: Set<String> = [
        "cat-file", "check-attr", "check-ignore", "diff", "for-each-ref", "log", "ls-files",
        "ls-remote", "merge-base", "reflog", "rev-list", "rev-parse", "show", "status",
    ]

    static func isRead(_ arguments: [String]) -> Bool {
        guard let verb = arguments.first else { return false }
        switch verb {
        case "config": return arguments.contains("--get") || arguments.contains("--get-regexp")
        case "worktree": return arguments.dropFirst().first == "list"
        case "remote": return arguments.count == 1 || arguments.dropFirst().first == "get-url"
        case "symbolic-ref": return arguments.contains("-q") || arguments.contains("--quiet")
        default: return reads.contains(verb)
        }
    }

    func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError) -> Data
    {
        if !Self.isRead(arguments) {
            Issue.record("Seam ran git \(arguments.joined(separator: " ")), which isn't a read")
        }
        return try await inner.run(arguments, in: directory, input: input)
    }
}

/// Stands in for gh: answers from what the test set, records every call, and can hold calls
/// until released.
final class FakeGitHub: GitHubClient, Sendable {
    private struct State {
        var open: [PullRequest] = []
        var byHead: [String: PullRequest] = [:]
        var error: GitHubError?
        var calls: [String] = []
        var holding = false
        /// Holds only calls whose name starts with this, when set.
        var holdingPrefix: String?
        var held: [CheckedContinuation<Void, Never>] = []
        var watchers: [(count: Int, resume: @Sendable () -> Void)] = []
        var threads: [Int: [GitHubReviewThread]] = [:]
        var threadReads: [Int] = []
        var threadError: GitHubError?
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    /// The PRs whose review threads were read, in order; kept apart from `calls`.
    var threadReads: [Int] { state.withLock { $0.threadReads } }

    func answer(threads: [GitHubReviewThread], for number: Int) {
        state.withLock { $0.threads[number] = threads }
    }

    func failThreads(_ error: GitHubError?) {
        state.withLock { $0.threadError = error }
    }
    /// Reads of the repo's open list: one per refresh that reached gh.
    var reads: Int { calls.count { $0.hasPrefix("open ") } }

    func answer(open: [PullRequest] = [], byHead: [String: PullRequest] = [:]) {
        state.withLock {
            $0.open = open
            $0.byHead = byHead
            $0.error = nil
        }
    }

    func fail(_ error: GitHubError) {
        state.withLock { $0.error = error }
    }

    func hold(_ prefix: String? = nil) {
        state.withLock {
            $0.holding = true
            $0.holdingPrefix = prefix
        }
    }

    func release() {
        let held = state.withLock { state in
            state.holding = false
            defer { state.held = [] }
            return state.held
        }
        for continuation in held { continuation.resume() }
    }

    /// Returns once gh has been called `count` times.
    func called(_ count: Int) async {
        await waitCancellably { resume in
            let done = state.withLock { state in
                if state.calls.count >= count { return true }
                state.watchers.append((count, resume))
                return false
            }
            if done { resume() }
        }
    }

    private func call(_ name: String) async throws(GitHubError) {
        await withCheckedContinuation { continuation in
            let (holding, ready) = state.withLock { state in
                state.calls.append(name)
                let holds = state.holding && state.holdingPrefix.map(name.hasPrefix) != false
                if holds { state.held.append(continuation) }
                let count = state.calls.count
                let ready = state.watchers.filter { $0.count <= count }.map(\.resume)
                state.watchers.removeAll { $0.count <= count }
                return (holds, ready)
            }
            for watcher in ready { watcher() }
            if !holding { continuation.resume() }
        }
        if let error = state.withLock({ $0.error }) { throw error }
    }

    func hosts() async throws(GitHubError) -> [String] {
        try await call("hosts")
        return ["github.com"]
    }

    /// Without reviews and checks, like gh's list: they come from `pullRequest(_:in:)`.
    func openPullRequests(in repo: GitHubRepo) async throws(GitHubError) -> [PullRequest] {
        try await call("open \(repo.slug)")
        return state.withLock { $0.open }.map { summary in
            var summary = summary
            summary.review = .none
            summary.checks = .init()
            return summary
        }
    }

    func pullRequest(_ number: Int, in repo: GitHubRepo) async throws(GitHubError)
        -> PullRequest
    {
        try await call("view \(number)")
        let found = state.withLock { state in
            (state.open + state.byHead.values).first { $0.number == number }
        }
        guard let found else { throw .failed("no pull request \(number)") }
        return found
    }

    func latestPullRequest(from branch: String, in repo: GitHubRepo) async throws(GitHubError)
        -> PullRequest?
    {
        try await call("head \(branch)")
        return state.withLock { $0.byHead[branch] }
    }

    func reviewThreads(_ number: Int, in repo: GitHubRepo) async throws(GitHubError)
        -> [GitHubReviewThread]
    {
        let (threads, error) = state.withLock { state in
            state.threadReads.append(number)
            return (state.threads[number] ?? [], state.threadError)
        }
        if let error { throw error }
        return threads
    }
}

@MainActor
final class OpenedURLs {
    var urls: [URL] = []
}

/// A catalog command by id, as menus and the palette run it.
@MainActor
func command(_ id: String) throws -> SeamCommand {
    try #require(CommandCatalog.all.first { $0.id == id })
}

/// One short turn of the run loop, for AppKit and SwiftUI layout; a sync function, since an
/// async one can't run the loop itself.
@MainActor
func runLoopOnce() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
}

/// The real diff pane in a window that's never shown, for driving it end to end.
@MainActor
struct CardWindow {
    let window: NSWindow

    init(session: RepoSession, review: WorktreeReview) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: DiffPane(session: session, review: review))
    }

    /// Settles until `condition` holds, for a bounded time; false if it never did.
    func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if condition() {
                await settle()
                return true
            }
            await settle()
        }
        return condition()
    }

    /// Lets SwiftUI, AppKit and the card's main-actor tasks all catch up.
    func settle() async {
        for _ in 0..<30 {
            runLoopOnce()
            await Task.yield()
        }
    }
}
