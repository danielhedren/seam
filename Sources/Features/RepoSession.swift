import AppKit
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
    var showsPalette = false
    /// Which of the three columns show; ⌘\ and ⌘⌥\ toggle the sidebars.
    var columns = Columns.all

    enum Columns {
        case all
        case filesAndDiff
        case diffOnly
    }
    var showsBasePicker = false
    /// Bumped by Edit › Filter Files; the window moves focus to the filter field.
    var filterFocusRequests = 0
    /// Find in the diff (SPEC §8.5): the bar, its query, and "current of total".
    var showsFind = false
    var findQuery = ""
    var findResult: (current: Int?, total: Int) = (nil, 0)
    /// Bumped by Edit › Find while the bar is already open, to focus its field again.
    var findFocusRequests = 0
    let diff = DiffController()

    private let services: SeamServices
    private var repoState = RepoState()
    private var monitorTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var isClosed = false
    private var rowsTask: Task<Void, Never>?
    private var deferredActivity: [String: Task<Void, Never>] = [:]
    private var staleActivity: Set<String> = []
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    init(directory: URL, services: SeamServices) {
        self.directory = directory
        self.services = services
    }

    var settings: AppSettings { services.settings }

    /// The diff or the file list has keyboard focus, so single-letter shortcuts apply (SPEC §9).
    /// The sheet and popover are separate windows, so the canvas keeps first responder under them;
    /// their text fields must still get every key.
    var reviewHasFocus: Bool {
        (diffHasFocus || fileListHasFocus) && !showsSwitcher && !showsBasePicker && !showsPalette
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
            await services.store.noteOpened(directory)
            // The list shows as soon as it's known; rows fill in their counts as they arrive.
            try await listWorktrees()
            guard !isClosed else { return }
            state = .open
            let last = repoState.selectedWorktree.flatMap { id in reviews.first { $0.id == id } }
            select(last?.id ?? worktree.path)
            startMonitor()
            startBackgroundFetch()
            rowsTask = Task { [weak self] in await self?.refreshRows(skippingSelected: true) }
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
    private func listWorktrees() async throws(GitError) {
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
            let review = WorktreeReview(worktree: worktree, services: services)
            review.restore(
                repoState.worktrees[worktree.id],
                override: worktree.branch.flatMap { repoState.baseOverrides[$0] })
            return review
        }
        if let selectedID, !reviews.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    /// Detection and counts for every row, at most eight at a time: dozens of simultaneous git
    /// processes contend for the same pack files. The selected worktree's own load detects it,
    /// so a first refresh can skip it.
    private func refreshRows(skippingSelected: Bool) async {
        let limit = 8
        let selectedID = selectedID
        // Refs live in the common git dir, so one listing serves every row.
        var refs: RefSnapshot?
        if let repository {
            refs = try? await RefSnapshot.load(in: repository.anchor, git: services.git)
        }
        await withTaskGroup(of: Void.self) { group in
            for (index, review) in reviews.enumerated() {
                if index >= limit { await group.next() }
                group.addTask { [refs] in
                    if !(skippingSelected && review.id == selectedID) {
                        await review.refreshDetection(refs: refs)
                    }
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
        if let anchor = diff.anchor { selected?.savedAnchor = anchor }
        selected?.cancelLoading()
        selectedID = id
        repoState.selectedWorktree = id
        persist()
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
        let settings = services.settings
        settings.layoutMode = settings.layoutMode == .unified ? .split : .unified
    }

    func showFind() {
        showsFind = true
        findFocusRequests += 1
    }

    func closeFind() {
        showsFind = false
        findQuery = ""
        diff.search("")
        diff.focus()
    }

    private(set) var isFetching = false
    private var fetchLoop: Task<Void, Never>?

    /// Fetches every `fetchInterval` minutes while that's on (SPEC §5.5), and restarts when the
    /// setting changes, so nothing runs at all while it's off.
    private func startBackgroundFetch() {
        fetchLoop?.cancel()
        guard !isClosed else { return }
        withObservationTracking {
            _ = settings.fetchInterval
        } onChange: { [weak self] in
            Task { @MainActor in self?.startBackgroundFetch() }
        }
        let minutes = settings.fetchInterval
        guard minutes > 0 else { return }
        let clock = services.clock
        fetchLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .seconds(60 * minutes))
                guard let self, !self.isClosed, !Task.isCancelled else { return }
                self.fetch(inBackground: true)
            }
        }
    }

    /// `f`: `git fetch --prune` for the repo (SPEC §5.5). The refs it changes reach every row
    /// through the same path as any other ref change. A fetch that stalls (a network that
    /// doesn't answer) is cancelled after two minutes so `f` doesn't stay disabled.
    func fetch(inBackground: Bool = false) {
        guard let repository, !isFetching else { return }
        isFetching = true
        let (git, clock) = (services.git, services.clock)
        Task { [weak self] in
            let failure: GitError? = await withTaskGroup(of: GitError?.self) { group in
                group.addTask {
                    do throws(GitError) {
                        _ = try await git.run(
                            ["fetch", "--prune", "--quiet"], in: repository.anchor)
                        return nil
                    } catch {
                        return error
                    }
                }
                group.addTask {
                    try? await clock.sleep(for: .seconds(120))
                    return .cancelled
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, !self.isClosed else { return }
            defer { isFetching = false }
            if let failure {
                logger.error("fetch failed: \(failure)")
                if !inBackground {
                    selected?.report(.fetchFailed(WorktreeReview.describe(failure)))
                }
                return
            }
            await apply(RepoChange(refs: true))
        }
    }

    /// The window's undo manager; viewed toggles are the only state changes that can be undone.
    weak var undoManager: UndoManager?

    /// `v`: toggles the current file's mark and, when it became viewed, moves to the next
    /// unviewed file. Undo restores the mark exactly (SPEC §9).
    func toggleViewed(_ path: String? = nil, advance: Bool = true) {
        guard let review = selected, let path = path ?? review.currentFile,
            let previous = review.toggleViewed(path)
        else { return }
        persist()
        registerViewedUndo(review, path, previous)
        if advance, review.viewedStatus(path) == .viewed,
            let next = review.nextUnviewed(after: path), next != path
        {
            review.currentFile = next
            diff.scroll(toFile: next)
        }
    }

    private func registerViewedUndo(_ review: WorktreeReview, _ path: String, _ mark: String?) {
        let current = review.viewed.marks[path]
        undoManager?.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated {
                review.restoreViewed(mark, for: path)
                session.persist()
                session.registerViewedUndo(review, path, current)
            }
        }
        undoManager?.setActionName(
            current == nil
                ? String(localized: "Mark as Not Viewed", bundle: .module)
                : String(localized: "Mark as Viewed", bundle: .module))
    }

    /// `o`: opens the reader's file and line in their editor, inside the reviewed worktree.
    /// Without a `file`, opens what the reader is on; with one, its first changed line.
    func openInEditor(_ command: EditorCommand? = nil, file: String? = nil) {
        guard let review = selected,
            let location = file.map({ ($0, review.firstChangedLine(of: $0)) })
                ?? diff.readingLocation
        else { return }
        let command = command ?? services.settings.editor
        let path = review.worktree.path.appending(path: location.0).path
        guard FileManager.default.fileExists(atPath: path) else {
            review.report(
                .editorFailed(String(localized: "\(location.0) no longer exists.", bundle: .module))
            )
            return
        }
        let line = command.commandLine(path: path, line: location.1)
        let launcher = services.launcher
        Task {
            do {
                try await launcher.run(line)
            } catch {
                let message = (error as? LaunchFailed)?.message ?? error.localizedDescription
                review.report(.editorFailed(message))
            }
        }
    }

    /// The file's absolute path in the reviewed worktree, or its path in the repository.
    func copyPath(_ file: String, relative: Bool, to pasteboard: NSPasteboard = .general) {
        guard let review = selected else { return }
        let text = relative ? file : review.worktree.path.appending(path: file).path
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func revealInFinder(_ file: String) {
        guard let review = selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting([review.worktree.path.appending(path: file)])
    }

    func dismissStaleParent() {
        selected?.dismissStaleParent()
        persist()
    }

    func toggleWhitespace() {
        selected?.toggleWhitespace()
        persist()
    }

    func toggleWrap() {
        selected?.toggleWrap()
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

    func persist() {
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
        guard !isClosed else { return }
        if change.refs {
            let before = reviews.map(\.id)
            do {
                try await listWorktrees()
            } catch {
                logger.error("worktree list failed: \(error)")
            }
            await refreshRows(skippingSelected: false)
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
        if let anchor = diff.anchor { selected?.savedAnchor = anchor }
        persist()
        isClosed = true
        monitorTask?.cancel()
        monitorTask = nil
        rowsTask?.cancel()
        fetchLoop?.cancel()
        for task in deferredActivity.values { task.cancel() }
        selected?.cancelLoading()
    }

    var isWatching: Bool { monitorTask != nil }

    /// An open request (`seam`, a drop, Open Recent). A worktree created since the list was read
    /// isn't in it yet, so the list is read again first; the base applies only if that worktree
    /// really got selected.
    func handle(worktree: String, base: String?) async {
        if !reviews.contains(where: { $0.id == worktree }) { await relistWorktrees() }
        select(worktree)
        guard selectedID == worktree, let base else { return }
        await setTypedBase(base)
    }

    /// The diff scrolled to another file. Saving here, not only on switch or close, keeps the
    /// position across ⌘Q, where nothing else gets a chance to run.
    func noteReading(_ path: String?) {
        guard let review = selected else { return }
        review.currentFile = path
        if let anchor = diff.anchor { review.savedAnchor = anchor }
        persist()
    }

    /// For an open request naming a worktree the list doesn't have yet.
    func relistWorktrees() async {
        let before = reviews.map(\.id)
        try? await listWorktrees()
        guard reviews.map(\.id) != before else { return }
        startMonitor()
        await refreshRows(skippingSelected: false)
    }

    func recentRepositories() async -> [URL] {
        await services.store.recentRepositories()
    }

    /// Waits for every row's detection and counts.
    func rowsLoaded() async {
        await rowsTask?.value
    }

    /// Waits for in-flight work; tests use it instead of sleeping.
    func settled() async {
        await selected?.loaded()
        await rowsTask?.value
        await saveTask?.value
    }
}
