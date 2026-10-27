import Foundation
import GitKit
import Observation
import SeamCore

/// A repo's pull requests, read through gh and kept current (SPEC §7.8). Owned by
/// `RepoSession`; rows read their branch's.
@MainActor
@Observable
package final class RepoPullRequests {
    package enum Status: Equatable {
        case unknown
        /// No remote points at a GitHub host.
        case notGitHub
        case ready
        case failed(GitHubError)
    }

    /// What asked for a refresh. A forced one doesn't wait out the spacing between refreshes.
    enum Trigger {
        case open, refs, activation, poll, reload, settings

        var isForced: Bool {
            switch self {
            case .open, .reload, .settings: true
            case .refs, .activation, .poll: false
            }
        }
    }

    static let spacing = Duration.seconds(15)
    static let pollInterval = Duration.seconds(120)
    static let pendingChecksInterval = Duration.seconds(30)
    static let freshness = Duration.seconds(60)
    static let firstBackoff = Duration.seconds(60)
    static let longestBackoff = Duration.seconds(960)
    /// In the background, only while a notification needs them (SPEC §7.10).
    static let backgroundInterval = Duration.seconds(300)
    static let backgroundChecksInterval = Duration.seconds(60)

    package private(set) var saved = SavedPullRequests()
    package private(set) var status = Status.unknown
    /// Where the PRs were last read from.
    private(set) var repo: GitHubRepo?
    /// Counts finished refreshes, for tests to wait on.
    private(set) var refreshes = 0
    /// Whether a read worked since the session opened; what was kept from before isn't news.
    private(set) var hasRead = false
    /// Set by the window; polling skips while the app is in the background.
    var appIsActive = true
    /// Whether a notification kind that needs pull requests is on, so they're read in the
    /// background too.
    @ObservationIgnored var readsInBackground: @MainActor () -> Bool = { false }
    /// Runs after every refresh, so the session can save what was read.
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Runs after every read that worked, with what was read and where from.
    @ObservationIgnored var onRead: ((SavedPullRequests, GitHubRepo) async -> Void)?

    private let services: SeamServices
    private let directory: URL
    /// The branches to look up: every worktree's, and every local parent's.
    private let branches: @MainActor () -> [String]
    private var pending = false
    private var isRefreshing = false
    private var idleWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiter = 0
    private var pump: Task<Void, Never>?
    private var spacer: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var fresh: Task<Void, Never>?
    private var isFresh = false
    private var backoff: Duration?
    private var isStopped = false
    /// Branches with no open PR, looked up one by one; merged and closed PRs rarely change.
    private var lookups: [String: (pullRequest: PullRequest?, age: Stopwatch)] = [:]
    /// How long a lookup of a branch with no open PR counts as current.
    static let rereadAfter = Duration.seconds(600)
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    init(
        services: SeamServices, directory: URL, saved: SavedPullRequests?,
        branches: @escaping @MainActor () -> [String]
    ) {
        self.services = services
        self.directory = directory
        self.branches = branches
        if let saved { self.saved = saved }
    }

    /// The branch's PR, unless Settings turned pull requests off.
    package func pullRequest(for branch: String?) -> PullRequest? {
        guard services.settings.showsPullRequests, let branch else { return nil }
        return saved.byBranch[branch]
    }

    func baseRef(for branch: String) -> String? {
        saved.baseRefs[branch]
    }

    package func unpushedCount(for branch: String) -> Int? {
        saved.unpushed[branch]
    }

    // MARK: - Scheduling

    func request(_ trigger: Trigger) {
        guard !isStopped, services.settings.showsPullRequests else { return }
        if trigger == .activation, isFresh { return }
        if trigger == .poll, case .failed(let error) = status, !Self.isTransient(error) { return }
        pending = true
        if trigger.isForced {
            spacer?.cancel()
            spacer = nil
        }
        guard pump == nil else { return }
        pump = Task { [weak self] () -> Void in
            while let self, self.pending, !self.isStopped {
                self.pending = false
                self.isRefreshing = true
                let asked = await self.refresh()
                self.isRefreshing = false
                guard asked else { continue }
                let clock = self.services.clock
                let spacer = Task { _ = try? await clock.sleep(for: Self.spacing) }
                self.spacer = spacer
                self.wakeIdleWaiters()
                await spacer.value
                self.spacer = nil
            }
            self?.pump = nil
            self?.wakeIdleWaiters()
        }
    }

    /// Nothing is being read, and nothing will be until the clock moves.
    private var isIdle: Bool { !isRefreshing && (pump == nil || spacer != nil) }

    /// Waits until `isIdle`; tests use it instead of sleeping.
    func idle() async {
        guard !isIdle else { return }
        nextWaiter += 1
        let id = nextWaiter
        // A cancelled waiter returns, so a test that never sees idle fails at its time limit.
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.idleWaiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func wakeIdleWaiters() {
        guard isIdle else { return }
        let waiters = idleWaiters.values
        idleWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    func stop() {
        isStopped = true
        for task in [pump, spacer, poller, fresh] { task?.cancel() }
        let waiters = idleWaiters.values
        idleWaiters = [:]
        for waiter in waiters { waiter.resume() }
    }

    private static func isTransient(_ error: GitHubError) -> Bool {
        switch error {
        case .rateLimited, .offline, .failed, .cancelled: true
        case .notInstalled, .notSignedIn: false
        }
    }

    /// Polls only once gh has answered for this repo: a repo without GitHub, or a Mac without
    /// gh, never wakes up for it.
    private func startPolling() {
        guard poller == nil else { return }
        let clock = services.clock
        poller = Task { [weak self] in
            while let interval = self?.nextPoll {
                do { try await clock.sleep(for: interval) } catch { return }
                guard let self, self.appIsActive || self.readsInBackground() else { continue }
                self.request(.poll)
                // The next wait depends on what this read finds.
                await self.idle()
            }
        }
    }

    var nextPoll: Duration? {
        guard !isStopped else { return nil }
        if let backoff { return backoff }
        let checking = saved.byBranch.values.contains { $0.state == .open && $0.checks.pending > 0 }
        if !appIsActive, readsInBackground() {
            return checking ? Self.backgroundChecksInterval : Self.backgroundInterval
        }
        return checking ? Self.pendingChecksInterval : Self.pollInterval
    }

    private func markFresh() {
        isFresh = true
        fresh?.cancel()
        let clock = services.clock
        fresh = Task { [weak self] in
            do { try await clock.sleep(for: Self.freshness) } catch { return }
            self?.isFresh = false
        }
    }

    // MARK: - Reading

    /// Returns whether gh ran, so the caller spaces out the next refresh.
    private func refresh() async -> Bool {
        let interval = signposter.beginInterval("pullRequests")
        defer {
            refreshes += 1
            signposter.endInterval("pullRequests", interval)
        }
        let git = services.git
        guard let refs = try? await RefSnapshot.load(in: directory, git: git) else { return false }
        let remotes = await PullRequestTargets.remotes(in: directory, refs: refs, git: git)
        let account = services.github
        do {
            let hosts = try await account.gitHubHosts(among: Set(remotes.values.map(\.host)))
            guard !isStopped, services.settings.showsPullRequests else { return false }
            guard let targets = PullRequestTargets(remotes: remotes, hosts: hosts, refs: refs)
            else {
                status = .notGitHub
                saved = SavedPullRequests()
                onUpdate?()
                return false
            }
            repo = targets.repo
            let read = try await read(targets, refs: refs)
            guard !isStopped else { return true }
            saved = read
            status = .ready
            hasRead = true
            backoff = nil
            account.note(nil)
            markFresh()
            startPolling()
            await onRead?(read, targets.repo)
        } catch {
            guard !isStopped else { return true }
            logger.info("pull requests unavailable: \(String(describing: error), privacy: .public)")
            status = .failed(error)
            account.note(error)
            if Self.isTransient(error) {
                backoff = min((backoff ?? Self.firstBackoff / 2) * 2, Self.longestBackoff)
                startPolling()
            }
            onUpdate?()
            return error != .notInstalled
        }
        onUpdate?()
        return true
    }

    private enum Job: Sendable {
        /// A branch with no open PR: its latest one in any state.
        case lookUp(String)
        /// An open PR's reviews and checks, which the list leaves out.
        case details(String, Int)

        var branch: String {
            switch self {
            case .lookUp(let branch), .details(let branch, _): branch
            }
        }
    }

    /// The open list first, shown as soon as it's in with the reviews and checks last read; then
    /// those and the branches without an open PR, side by side.
    private func read(_ targets: PullRequestTargets, refs: RefSnapshot) async throws(GitHubError)
        -> SavedPullRequests
    {
        let client = services.github.client
        let open = try await client.openPullRequests(in: targets.repo)
        // The default branch is what PRs merge into, not a head worth asking about.
        let wanted = Set(branches()).subtracting([refs.defaultBranch(of: targets.remote) ?? "main"])
        let previous = saved.byBranch
        var result = SavedPullRequests(read: .now)
        var jobs: [Job] = []
        for branch in wanted.sorted() {
            if var pullRequest = targets.pullRequest(for: branch, in: open) {
                if let last = previous[branch], last.number == pullRequest.number {
                    pullRequest.review = last.review
                    pullRequest.checks = last.checks
                    pullRequest.mergeState = last.mergeState
                }
                result.byBranch[branch] = pullRequest
                jobs.append(.details(branch, pullRequest.number))
            } else if let cached = lookups[branch],
                cached.age.elapsed < Self.rereadAfter,
                cached.pullRequest?.state != PullRequest.State.open
            {
                result.byBranch[branch] = cached.pullRequest
            } else {
                result.byBranch[branch] = previous[branch]
                jobs.append(.lookUp(branch))
            }
        }
        if !jobs.isEmpty {
            await finish(result, targets, refs)
        }
        let repo = targets.repo
        let done = try await Self.concurrently(jobs) { job throws(GitHubError) -> PullRequest? in
            switch job {
            case .lookUp(let branch):
                return try await client.latestPullRequest(
                    from: targets.head(of: branch).name, in: repo
                ).flatMap { targets.pullRequest(for: branch, in: [$0]) }
            case .details(_, let number):
                return try await client.pullRequest(number, in: repo)
            }
        }
        for (job, pullRequest) in done {
            if case .lookUp(let branch) = job {
                lookups[branch] = (pullRequest, Stopwatch(services.clock))
                // Beyond the open list's limit: its checks weren't read.
                if let pullRequest, pullRequest.state == .open {
                    result.byBranch[branch] = try await client.pullRequest(
                        pullRequest.number, in: repo)
                    continue
                }
            }
            result.byBranch[job.branch] = pullRequest
        }
        return await finish(result, targets, refs, publish: false)
    }

    /// Adds where each PR merges into and what isn't pushed; shows the result unless told not to.
    @discardableResult
    private func finish(
        _ read: SavedPullRequests, _ targets: PullRequestTargets, _ refs: RefSnapshot,
        publish: Bool = true
    ) async -> SavedPullRequests {
        var result = read
        for (branch, pullRequest) in result.byBranch {
            result.baseRefs[branch] = targets.baseRef(of: pullRequest, refs: refs)
            guard pullRequest.state == .open, refs.tip(of: branch) != pullRequest.headCommit
            else { continue }
            result.unpushed[branch] = await PullRequest.unpushedCount(
                of: branch, headCommit: pullRequest.headCommit, in: directory, git: services.git)
        }
        if publish, !isStopped { saved = result }
        return result
    }

    /// Runs `body` for each item, at most six gh processes at once; the first failure wins.
    static func concurrently<Item: Sendable, Value: Sendable>(
        _ items: [Item],
        _ body: @escaping @Sendable (Item) async throws(GitHubError) -> Value
    ) async throws(GitHubError) -> [(Item, Value)] {
        let results = await withTaskGroup(of: (Item, Result<Value, GitHubError>).self) {
            group in
            var results: [(Item, Result<Value, GitHubError>)] = []
            for (index, item) in items.enumerated() {
                if index >= 6, let next = await group.next() { results.append(next) }
                group.addTask {
                    (item, await Result { () async throws(GitHubError) in try await body(item) })
                }
            }
            for await next in group { results.append(next) }
            return results
        }
        return try results.map { (item, result) throws(GitHubError) in (item, try result.get()) }
    }
}

/// Time since it was made, by the injected clock, so tests can move it.
package struct Stopwatch: Sendable {
    private let read: @Sendable () -> Duration

    init(_ clock: any Clock<Duration>) {
        read = Self.start(clock)
    }

    var elapsed: Duration { read() }

    private static func start<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}
