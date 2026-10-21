import DiffView
import Foundation
import GitKit
import Observation
import SeamCore
import os

enum WorktreeSort: String, CaseIterable, Sendable {
    case recent
    case name
}

/// One window's state: the repo's worktrees, the selection, and live updates (SPEC §8.2).
/// Views read it and call its methods; nothing else mutates it.
@MainActor
@Observable
final class RepoSession {
    enum OpenState: Equatable {
        case opening
        case open
        case failed(String)
    }

    let directory: URL
    private(set) var state = OpenState.opening
    private(set) var repository: Repository?
    private(set) var reviews: [WorktreeReview] = []
    private(set) var selectedID: String?
    var sort = WorktreeSort.recent
    var hidesMissing = false
    var diffHasFocus = false
    var fileListHasFocus = false
    var showsSwitcher = false
    var showsBasePicker = false
    /// Bumped by Edit › Filter Files; the window moves focus to the filter field.
    var filterFocusRequests = 0
    let diff = DiffController()

    private let services: SeamServices
    private let defaultMode: DiffLayoutMode
    private var repoState = RepoState()
    private var monitorTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var isClosed = false
    private var deferredActivity: [String: Task<Void, Never>] = [:]
    private var staleActivity: Set<String> = []
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    init(directory: URL, services: SeamServices, defaultMode: DiffLayoutMode = .unified) {
        self.directory = directory
        self.services = services
        self.defaultMode = defaultMode
    }

    /// The diff or the file list has keyboard focus, so single-letter shortcuts apply (SPEC §9).
    /// The sheet and popover are separate windows, so the canvas keeps first responder under them;
    /// their text fields must still get every key.
    var reviewHasFocus: Bool {
        (diffHasFocus || fileListHasFocus) && !showsSwitcher && !showsBasePicker
    }

    var selected: WorktreeReview? {
        reviews.first { $0.id == selectedID }
    }

    var repositoryName: String {
        guard let repository else { return directory.lastPathComponent }
        let common = repository.commonDirectory
        return common.lastPathComponent == ".git"
            ? common.deletingLastPathComponent().lastPathComponent : common.lastPathComponent
    }

    /// Main worktree pinned first, then by recent change or name (SPEC §7.2).
    var sortedReviews: [WorktreeReview] {
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

    func open() async {
        let interval = signposter.beginInterval("openRepository")
        defer { signposter.endInterval("openRepository", interval) }
        let service = RepositoryService(git: services.git, fileSystem: services.fileSystem)
        do {
            let (repository, worktree) = try await service.open(directory)
            self.repository = repository
            repoState = await services.store.load(repository)
            await services.store.noteOpened(repository.anchor)
            try await reloadWorktrees()
            guard !isClosed else { return }
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

    func select(_ id: String?) {
        guard let id, id != selectedID, let review = reviews.first(where: { $0.id == id }) else {
            return
        }
        selected?.savedAnchor = diff.anchor
        selected?.cancelLoading()
        selectedID = id
        review.reloadDiff()
    }

    /// `⌘1`…`⌘9`: the worktree at that position in the list.
    func select(position: Int) {
        let sorted = sortedReviews
        guard sorted.indices.contains(position) else { return }
        select(sorted[position].id)
    }

    func selectAdjacent(_ delta: Int) {
        let sorted = sortedReviews
        guard !sorted.isEmpty else { return }
        let current = sorted.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        select(sorted[(current + delta + sorted.count) % sorted.count].id)
    }

    // MARK: - Review intents

    func setScope(_ scope: ReviewScope) {
        selected?.setScope(scope)
        persist()
    }

    func toggleMode() {
        guard let review = selected else { return }
        review.setMode(review.mode == .unified ? .split : .unified)
        persist()
    }

    func setBaseOverride(_ ref: String?) {
        guard let review = selected else { return }
        review.setOverride(ref)
        if let branch = review.worktree.branch {
            repoState.baseOverrides[branch] = review.baseOverride
        }
        persist()
    }

    /// A ref typed into the base picker, stored by its full name so it matches the candidates.
    /// One that doesn't resolve is kept as typed, and the load reports it as gone.
    func setTypedBase(_ name: String) async {
        guard let review = selected else { return }
        let resolved = try? await BaseDetector(git: services.git)
            .resolveRef(name, in: review.worktree.path)
        guard review.id == selectedID else { return }
        setBaseOverride(resolved ?? name)
    }

    func toggleCollapsed(_ path: String? = nil) {
        guard let review = selected, let path = path ?? review.currentFile else { return }
        review.toggleCollapsed(path)
    }

    func reload() {
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
        // Ending the loop drops the stream, which stops FSEvents.
        monitorTask = Task { [weak self] in
            for await change in changes {
                guard let self, !self.isClosed else { return }
                await self.apply(change)
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
            selected?.reloadDiff()
            if reviews.map(\.id) != before {
                // Restarting from here would cancel this very task mid-apply.
                Task { [weak self] in self?.restartMonitor() }
            }
            return
        }
        for id in change.worktrees {
            guard let review = reviews.first(where: { $0.id == id }) else { continue }
            review.noteChange(at: .now)
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

    /// A new worktree list needs a new watch. Edits made while the list reloaded reached neither
    /// monitor, so every row's counts are refreshed once more.
    private func restartMonitor() {
        guard !isClosed else { return }
        startMonitor()
        for review in reviews where review.id != selectedID {
            refreshHiddenActivity(review)
        }
    }

    /// Stops watching; the window is closing.
    func close() {
        isClosed = true
        monitorTask?.cancel()
        monitorTask = nil
        for task in deferredActivity.values { task.cancel() }
        selected?.cancelLoading()
    }

    var isWatching: Bool { monitorTask != nil }

    /// Waits for in-flight work; tests use it instead of sleeping.
    func settled() async {
        await selected?.loaded()
        await saveTask?.value
    }
}
