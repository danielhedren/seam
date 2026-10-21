import DiffView
import Foundation
import GitKit
import Observation
import SeamCore
import os

public enum WorktreeSort: String, CaseIterable, Sendable {
    case recent
    case name
}

/// One window's state: the repo's worktrees, the selection, and live updates (SPEC §8.2).
/// Views read it and call its methods; nothing else mutates it.
@MainActor
@Observable
public final class RepoSession {
    public enum OpenState: Equatable {
        case opening
        case open
        case failed(String)
    }

    public let directory: URL
    public private(set) var state = OpenState.opening
    public private(set) var repository: Repository?
    public private(set) var reviews: [WorktreeReview] = []
    public private(set) var selectedID: String?
    public var sort = WorktreeSort.recent
    public var hidesMissing = false
    public var diffHasFocus = false
    public var fileListHasFocus = false
    public var showsSwitcher = false
    public var showsBasePicker = false
    /// Bumped by Edit › Filter Files; the window moves focus to the filter field.
    public var filterFocusRequests = 0
    public let diff = DiffController()

    private let services: SeamServices
    private let defaultMode: DiffLayoutMode
    private var repoState = RepoState()
    private var monitorTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var deferredActivity: [String: Task<Void, Never>] = [:]
    private var staleActivity: Set<String> = []
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    public init(directory: URL, services: SeamServices, defaultMode: DiffLayoutMode = .unified) {
        self.directory = directory
        self.services = services
        self.defaultMode = defaultMode
    }

    /// The diff or the file list has keyboard focus, so single-letter shortcuts apply (SPEC §9).
    public var reviewHasFocus: Bool { diffHasFocus || fileListHasFocus }

    public var selected: WorktreeReview? {
        reviews.first { $0.id == selectedID }
    }

    public var repositoryName: String {
        guard let repository else { return directory.lastPathComponent }
        let common = repository.commonDirectory
        return common.lastPathComponent == ".git"
            ? common.deletingLastPathComponent().lastPathComponent : common.lastPathComponent
    }

    /// Main worktree pinned first, then by recent change or name (SPEC §7.2).
    public var sortedReviews: [WorktreeReview] {
        let visible = reviews.filter { !(hidesMissing && $0.worktree.isMissing) }
        let main = visible.filter(\.worktree.isMain)
        let others = visible.filter { !$0.worktree.isMain }.sorted { lhs, rhs in
            switch sort {
            case .name:
                return lhs.worktree.name.localizedStandardCompare(rhs.worktree.name)
                    == .orderedAscending
            case .recent:
                let (left, right) = (lhs.lastChange ?? .distantPast, rhs.lastChange ?? .distantPast)
                return left == right ? lhs.worktree.name < rhs.worktree.name : left > right
            }
        }
        return main + others
    }

    // MARK: - Opening

    public func open() async {
        let interval = signposter.beginInterval("openRepository")
        defer { signposter.endInterval("openRepository", interval) }
        let service = RepositoryService(git: services.git, fileSystem: services.fileSystem)
        do {
            let (repository, worktree) = try await service.open(directory)
            self.repository = repository
            repoState = await services.store.load(repository)
            await services.store.noteOpened(repository.anchor)
            try await reloadWorktrees()
            state = .open
            select(worktree.path)
            startMonitor()
        } catch {
            state = .failed(Self.openFailure(error))
        }
    }

    static func openFailure(_ error: GitError) -> String {
        if case .nonZeroExit(_, _, let stderr) = error, stderr.contains("not a git repository") {
            return String(
                localized: "Not a git repository. Choose another folder.", bundle: .module)
        }
        return WorktreeReview.describe(error)
    }

    /// Lists worktrees again, keeping the models of those that still exist, and refreshes every
    /// row concurrently so the list is ready within the §8.7 budget.
    private func reloadWorktrees() async throws(GitError) {
        guard let repository else { return }
        let worktrees = try await RepositoryService(
            git: services.git, fileSystem: services.fileSystem
        ).worktrees(of: repository)
        let existing = Dictionary(uniqueKeysWithValues: reviews.map { ($0.id, $0) })
        reviews = worktrees.map { worktree in
            if let review = existing[worktree.id] {
                review.update(worktree)
                return review
            }
            let review = WorktreeReview(worktree: worktree, mode: defaultMode, services: services)
            review.restore(
                repoState.worktrees[worktree.id],
                override: worktree.branch.flatMap { repoState.baseOverrides[$0] })
            return review
        }
        if let selectedID, !reviews.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        // Bounded: dozens of simultaneous git processes contend for the same pack files.
        let limit = 8
        await withTaskGroup(of: Void.self) { group in
            for (index, review) in reviews.enumerated() {
                if index >= limit { await group.next() }
                group.addTask {
                    await review.refreshDetection()
                    await review.refreshActivity()
                }
            }
        }
    }

    // MARK: - Selection

    public func select(_ id: String?) {
        guard let id, id != selectedID, let review = reviews.first(where: { $0.id == id }) else {
            return
        }
        selected?.savedAnchor = diff.anchor
        selected?.cancelLoading()
        selectedID = id
        review.reloadDiff()
    }

    /// `⌘1`…`⌘9`: the worktree at that position in the list.
    public func select(position: Int) {
        let sorted = sortedReviews
        guard sorted.indices.contains(position) else { return }
        select(sorted[position].id)
    }

    public func selectAdjacent(_ delta: Int) {
        let sorted = sortedReviews
        guard !sorted.isEmpty else { return }
        let current = sorted.firstIndex { $0.id == selectedID } ?? -delta
        select(sorted[(current + delta + sorted.count) % sorted.count].id)
    }

    // MARK: - Review intents

    public func setScope(_ scope: ReviewScope) {
        selected?.setScope(scope)
        persist()
    }

    public func toggleMode() {
        guard let review = selected else { return }
        review.setMode(review.mode == .unified ? .split : .unified)
        persist()
    }

    public func setBaseOverride(_ ref: String?) {
        guard let review = selected else { return }
        review.setOverride(ref)
        if let branch = review.worktree.branch {
            repoState.baseOverrides[branch] = review.baseOverride
        }
        persist()
    }

    public func toggleCollapsed(_ path: String? = nil) {
        guard let review = selected, let path = path ?? review.currentFile else { return }
        review.toggleCollapsed(path)
    }

    public func reload() {
        guard let review = selected else { return }
        Task {
            await review.refreshDetection()
            await review.refreshActivity()
            review.reloadDiff()
        }
    }

    private func persist() {
        guard let repository else { return }
        for review in reviews {
            repoState.worktrees[review.id] = review.persistentState
        }
        let (snapshot, previous, store) = (repoState, saveTask, services.store)
        saveTask = Task {
            await previous?.value
            await store.save(snapshot, for: repository)
        }
    }

    // MARK: - Live updates (SPEC §8.6)

    private func startMonitor() {
        monitorTask?.cancel()
        guard let repository else { return }
        let monitor = RepoMonitor(
            repository: repository, worktrees: reviews.map(\.worktree), watcher: services.watcher,
            git: services.git, clock: services.clock)
        let changes = monitor.changes()
        monitorTask = Task { [weak self] in
            for await change in changes {
                await self?.apply(change)
            }
        }
    }

    func apply(_ change: RepoChange) async {
        if change.refs {
            let before = reviews.map(\.id)
            do {
                try await reloadWorktrees()
            } catch {
                logger.error("worktree list failed: \(error)")
            }
            if reviews.map(\.id) != before { startMonitor() }
            selected?.reloadDiff()
            return
        }
        for id in change.worktrees {
            guard let review = reviews.first(where: { $0.id == id }) else { continue }
            if id == selectedID {
                await review.refreshActivity()
                review.reloadDiff()
            } else {
                refreshHiddenActivity(review)
            }
        }
    }

    /// Hidden rows refresh at most every 5 s, so build churn in many worktrees stays cheap.
    /// Changes inside the quiet period are caught by one more refresh at its end.
    private func refreshHiddenActivity(_ review: WorktreeReview) {
        guard deferredActivity[review.id] == nil else {
            staleActivity.insert(review.id)
            return
        }
        let clock = services.clock
        deferredActivity[review.id] = Task { [weak self] in
            repeat {
                self?.staleActivity.remove(review.id)
                await review.refreshActivity()
                try? await clock.sleep(for: .seconds(5))
            } while !Task.isCancelled && self?.staleActivity.contains(review.id) == true
            self?.deferredActivity[review.id] = nil
        }
    }

    /// Stops watching; the window is closing.
    public func close() {
        monitorTask?.cancel()
        for task in deferredActivity.values { task.cancel() }
        selected?.cancelLoading()
    }

    /// Waits for in-flight work; tests use it instead of sleeping.
    func settled() async {
        await selected?.loaded()
        await saveTask?.value
    }
}
