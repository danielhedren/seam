import DiffModel
import Foundation
import GitKit
import Observation
import SeamCore

package enum WorktreeSort: String, CaseIterable, Sendable {
    /// Worktrees with something awaiting the reader first, then by recent change.
    case attention
    case recent
    case name
}

/// One window's state: the repo's worktrees, the selection, and live updates (SPEC §8.2).
/// Views read it and call its methods; nothing else mutates it.
@MainActor
@Observable
package final class RepoSession {
    package enum OpenState: Equatable {
        case opening
        case open
        case failed(String)
    }

    package let directory: URL
    package private(set) var state = OpenState.opening
    private(set) var repository: Repository?
    /// The repo's review threads, once it's open (SPEC §7.7).
    package private(set) var threads: RepoThreads?
    private(set) var pullRequestThreads: PullRequestThreads?
    private var rowRefresh: Task<Void, Never>?
    /// A save asked for while one is being written; it runs once that one is done.
    private var saveIsWaiting = false
    /// What Seam couldn't read or save of its own state, shown above the diff (SPEC §11).
    package private(set) var stateProblem: String?
    private var stateProblemIsSaving = false
    private var rowRefreshPending = false
    /// The repo's pull requests, once it's open (SPEC §7.8).
    package private(set) var pullRequests: RepoPullRequests?
    package var showsThreadPanel = false
    /// While set, the agent prompt was just copied.
    package var promptCopied: Task<Void, Never>?
    /// Each worktree's open thread and draft, kept while another is shown (SPEC §7.7).
    var threadSelections: [String: ThreadSelection] = [:]
    package private(set) var reviews: [WorktreeReview] = []
    package private(set) var selectedID: String?
    package var sort = WorktreeSort.attention
    package var hidesMissing = false
    package var diffHasFocus = false
    package var fileListHasFocus = false
    package var showsSwitcher = false
    package var showsPalette = false
    /// The worktree column. The file list always shows: macOS's three-column split view ignores
    /// `.detailOnly` and can't collapse its middle column.
    package var showsWorktreeList = true
    package var showsBasePicker = false
    /// Bumped by Edit › Filter Files; the window moves focus to the filter field.
    package var filterFocusRequests = 0
    /// Bumped by Search in Review; the window moves focus to the search field once it shows.
    package var searchFocusRequests = 0
    package let diff: DiffController
    package let find: FindState

    package let services: SeamServices
    private var repoState = RepoState()
    private var monitorTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var keepingSeen: Task<Void, Never>?
    private var isClosed = false
    private var rowsTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    /// The recent repos going to Spotlight; tests wait on it.
    @ObservationIgnored private(set) var spotlightTask: Task<Void, Never>?
    /// An undone thread deletion being written back; tests wait on it.
    @ObservationIgnored var restoringThreads: Task<Void, Never>?
    private var deferredActivity: [String: Task<Void, Never>] = [:]
    private var staleActivity: Set<String> = []
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    package init(directory: URL, services: SeamServices) {
        self.directory = directory
        self.services = services
        let diff = DiffController()
        self.diff = diff
        find = FindState(diff: diff)
        find.onQueryChange = { [weak self] in self?.refreshDiffQuery() }
    }

    package var settings: AppSettings { services.settings }

    /// What the diff highlights: find's query while there is one, else the search Search shows.
    package var diffQuery: TextQuery {
        guard find.query.isEmpty else { return TextQuery(find.query) }
        guard let review = selected, review.isSearching else { return TextQuery() }
        return review.appliedSearch
    }

    func refreshDiffQuery() {
        diff.search(diffQuery)
    }

    /// Edit › Find › Search in Review.
    package func showSearch() {
        guard let review = selected else { return }
        review.navigator = .search
        searchFocusRequests += 1
    }

    /// The diff or the file list has keyboard focus, so single-letter shortcuts apply (SPEC §9).
    /// The sheet and popover are separate windows, so the canvas keeps first responder under them;
    /// their text fields must still get every key.
    package var reviewHasFocus: Bool {
        (diffHasFocus || fileListHasFocus) && !showsSwitcher && !showsBasePicker && !showsPalette
    }

    package var selected: WorktreeReview? {
        reviews.first { $0.id == selectedID }
    }

    package var repositoryName: String {
        guard let repository else { return directory.lastPathComponent }
        let common = repository.commonDirectory
        return common.lastPathComponent == ".git"
            ? common.deletingLastPathComponent().lastPathComponent : common.lastPathComponent
    }

    /// The main worktree pinned first, then by recent change or name; or by attention: those
    /// needing the reader, then those with work, then idle ones, main first among them (SPEC §7.2).
    package var sortedReviews: [WorktreeReview] {
        let visible = reviews.filter { !(hidesMissing && $0.worktree.isMissing) }
        func ordered(_ reviews: [WorktreeReview]) -> [WorktreeReview] {
            reviews.filter(\.worktree.isMain)
                + reviews.filter { !$0.worktree.isMain }.sorted { lhs, rhs in
                    switch sort {
                    case .name:
                        return lhs.worktree.name.localizedStandardCompare(rhs.worktree.name)
                            == .orderedAscending
                    case .recent, .attention:
                        let (left, right) = (
                            lhs.lastChange ?? .distantPast, rhs.lastChange ?? .distantPast
                        )
                        return left == right ? lhs.worktree.name < rhs.worktree.name : left > right
                    }
                }
        }
        guard sort == .attention else { return ordered(visible) }
        let needing = visible.filter(\.attention.needsReader)
        let rest = visible.filter { !$0.attention.needsReader }
        return ordered(needing) + ordered(rest.filter(\.hasWork))
            + ordered(rest.filter { !$0.hasWork })
    }

    // MARK: - Opening

    package func open() async {
        let interval = signposter.beginInterval("openRepository")
        defer { signposter.endInterval("openRepository", interval) }
        let service = RepositoryService(git: services.git, fileSystem: services.fileSystem)
        do {
            let (repository, worktree) = try await service.open(directory)
            self.repository = repository
            threads = RepoThreads(
                repository: repository, store: services.threads, git: services.git)
            let pullRequestThreads = PullRequestThreads(
                repository: repository, store: services.threads, client: services.github.client,
                clock: services.clock)
            pullRequestThreads.isShown = { [settings = services.settings] in
                settings.showsPullRequests
            }
            self.pullRequestThreads = pullRequestThreads
            repoState = await services.store.load(repository)
            stateProblem = await services.store.loadProblem(for: repository)
            startPullRequests(in: repository)
            await services.store.noteOpened(directory)
            // Spotlight lists what Open Recent does, and never holds up the window.
            spotlightTask = Task { [services] in
                await services.spotlight.replace(with: await services.store.recentRepositories())
            }
            // The list shows as soon as it's known; rows fill in their counts as they arrive.
            try await listWorktrees()
            guard !isClosed else { return }
            state = .open
            await threads?.start(watching: services.watcher)
            _ = await threads?.reader(in: worktree.path)
            await pullRequestThreads.start(watching: services.watcher)
            guard !isClosed else { return }
            let last = repoState.selectedWorktree.flatMap { id in reviews.first { $0.id == id } }
            select(last?.id ?? worktree.path)
            startMonitor()
            rowsTask = Task { [weak self] in
                await self?.refreshRows(skippingSelected: true)
                // After detection, so local parents are among the branches looked up.
                await self?.selected?.loaded()
                self?.pullRequests?.request(.open)
            }
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
            review.threads = threads
            review.pullRequestThreads = pullRequestThreads
            review.pullRequests = pullRequests
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
                group.addTask { [refs, threads] in
                    if !(skippingSelected && review.id == selectedID) {
                        await review.refreshDetection(refs: refs)
                    }
                    await review.refreshActivity()
                    // Whose turn a thread is depends on who the reader is in that worktree.
                    _ = await threads?.reader(in: review.id)
                }
            }
        }
    }

    // MARK: - Selection

    package func select(_ id: String?) {
        guard let id, id != selectedID, let review = reviews.first(where: { $0.id == id }) else {
            return
        }
        if let anchor = diff.anchor { selected?.savedAnchor = anchor }
        selected?.cancelLoading()
        selectedID = id
        // The diff reports only a change in whether it can show the thread, so a hidden one
        // comes back in the panel from here.
        if selectedThreadID != nil, threadSelections[id]?.isHidden == true {
            showsThreadPanel = true
        }
        // Known before the panel sorts threads by whose turn it is.
        Task { [threads] in _ = await threads?.reader(in: id) }
        repoState.selectedWorktree = id
        persist()
        review.reloadDiff()
    }

    /// `⌘1`…`⌘9`: the worktree at that position in the list.
    package func select(position: Int) {
        let sorted = sortedReviews
        guard sorted.indices.contains(position) else { return }
        select(sorted[position].id)
    }

    package func selectAdjacent(_ delta: Int) {
        let sorted = sortedReviews
        guard !sorted.isEmpty else { return }
        let current = sorted.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        select(sorted[(current + delta + sorted.count) % sorted.count].id)
    }

    // MARK: - Review intents

    package func selectCommits(_ selection: CommitSelection) {
        selected?.selectCommits(selection)
    }

    package func selectLatestCommit() {
        selected?.selectLatestCommit()
    }

    package func setScope(_ scope: ReviewScope) {
        selected?.setScope(scope)
        persist()
    }

    package func toggleMode() {
        let settings = services.settings
        settings.layoutMode = settings.layoutMode == .unified ? .split : .unified
    }

    /// The window's undo manager; viewed toggles are the only state changes that can be undone.
    package weak var undoManager: SessionUndo?

    /// `v`: toggles the current file's mark and, when it became viewed, moves to the next
    /// unviewed file. Undo restores the mark exactly (SPEC §9).
    package func toggleViewed(_ path: String? = nil, advance: Bool = true) {
        guard let review = selected, let path = path ?? review.currentFile,
            let previous = review.toggleViewed(path)
        else { return }
        persist()
        keepSeen(review, path)
        registerViewedUndo(review, path, previous)
        if advance, review.viewedStatus(path) == .viewed,
            let next = review.nextUnviewed(after: path), next != path
        {
            review.currentFile = next
            diff.scroll(toFile: next)
        }
    }

    /// Keeps what the reader saw, for Show Changes Since Viewed; in order, so a show waits for it.
    private func keepSeen(_ review: WorktreeReview, _ path: String) {
        guard let repository, let (id, text) = review.seenText(path) else { return }
        let (previous, store) = (keepingSeen, services.store)
        keepingSeen = Task {
            await previous?.value
            await store.keepSeen(text, id: id, for: repository)
        }
    }

    /// Review › Show Changes Since Viewed, or Show Full Diff when it's shown (SPEC §7.4). A
    /// version the store doesn't have may still be a git object, if it was committed.
    package func toggleSinceViewed(_ path: String? = nil) async {
        guard let review = selected, let path = path ?? review.currentFile else { return }
        if review.sinceViewed[path] != nil {
            review.showFullDiff(path)
            return
        }
        guard let repository, let id = review.sinceViewedID(path) else { return }
        await keepingSeen?.value
        var seen = await services.store.seen(id, for: repository)
        if seen == nil,
            let blob = try? await services.git.run(
                ["cat-file", "blob", id], in: review.worktree.path)
        {
            seen = String(decoding: blob, as: UTF8.self)
        }
        guard review.sinceViewedID(path) == id else { return }
        guard let seen else {
            review.report(.seenGone(path))
            return
        }
        review.showSinceViewed(path, seen: seen)
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
    package func openInEditor(_ command: EditorCommand? = nil, file: String? = nil) {
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
        launchEditor(command.commandLine(path: path, line: location.1), for: review)
    }

    /// Runs an editor command line; a failure shows on the worktree's banner.
    package func launchEditor(_ line: String, for review: WorktreeReview) {
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
    package func copyPath(_ file: String, relative: Bool) {
        guard let review = selected else { return }
        services.platform.copy(relative ? file : review.worktree.path.appending(path: file).path)
    }

    package func revealInFinder(_ file: String) {
        guard let review = selected else { return }
        services.platform.reveal(review.worktree.path.appending(path: file))
    }

    package func dismissStaleParent() {
        selected?.dismissStaleParent()
        persist()
    }

    package func dismissPullRequestBase() {
        selected?.dismissPullRequestBase()
        persist()
    }

    package func toggleWhitespace() {
        selected?.toggleWhitespace()
        persist()
    }

    package func toggleWrap() {
        selected?.toggleWrap()
        persist()
    }

    package func setBaseOverride(_ ref: String?) {
        guard let review = selected else { return }
        review.setOverride(ref)
        if let branch = review.worktree.branch {
            repoState.baseOverrides[branch] = review.baseOverride
        }
        persist()
    }

    /// A ref typed into the base picker, stored by its full name so it matches the candidates.
    /// One that doesn't resolve is kept as typed, and the load reports it as gone.
    package func setTypedBase(_ name: String) async {
        guard let review = selected else { return }
        let resolved = try? await BaseDetector(git: services.git)
            .resolveRef(name, in: review.worktree.path)
        guard review.id == selectedID else { return }
        setBaseOverride(resolved ?? name)
    }

    package func toggleCollapsed(_ path: String? = nil) {
        guard let review = selected, let path = path ?? review.currentFile else { return }
        review.toggleCollapsed(path)
    }

    package func reload() {
        guard let review = selected else { return }
        reloadTask = Task { [weak self] in
            await review.refreshDetection()
            await review.refreshActivity()
            // Only the selected worktree loads its diff (SPEC §8.6).
            guard self?.selectedID == review.id else { return }
            review.reloadDiff()
        }
        pullRequestThreads?.forgetReads()
        pullRequests?.request(.reload)
    }

    var savedPullRequests: SavedPullRequests? { repoState.pullRequests }

    func setPullRequests(_ pullRequests: RepoPullRequests) {
        self.pullRequests = pullRequests
    }

    func notePullRequests(_ saved: SavedPullRequests) {
        repoState.pullRequests = saved.byBranch.isEmpty ? nil : saved
        persist()
    }

    package func dismissStateProblem() {
        stateProblem = nil
        stateProblemIsSaving = false
    }

    /// Writes the state at once, since nothing runs on ⌘Q. Saves asked for while one is being
    /// written become one more write after it, with the state as it is then.
    func persist() {
        guard let repository else { return }
        guard saveTask == nil else {
            saveIsWaiting = true
            return
        }
        // Worktrees that are gone take their state with them.
        repoState.worktrees = Dictionary(
            uniqueKeysWithValues: reviews.map { ($0.id, $0.persistentState) })
        let (snapshot, store) = (repoState, services.store)
        saveTask = Task { [weak self] in
            let failure = await store.save(snapshot, for: repository)
            guard let self else { return }
            saveTask = nil
            if let failure {
                stateProblem = failure
                stateProblemIsSaving = true
            } else if stateProblemIsSaving {
                stateProblem = nil
                stateProblemIsSaving = false
            }
            if saveIsWaiting {
                saveIsWaiting = false
                persist()
            }
        }
    }

    // MARK: - Live updates (SPEC §8.6)

    private func startMonitor() {
        monitorTask?.cancel()
        guard !isClosed, let repository else { return }
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
            // The diff being read first: its parent may have moved, so it's detected again.
            if let selected {
                await selected.refreshDetection()
                selected.reloadDiff()
            }
            // A push moves a remote ref, so it's also the cue that a PR may have changed.
            pullRequests?.request(.refs)
            refreshRowsAfterRefs()
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

    /// Every row's detection and counts after a ref change, off the path that reloads the shown
    /// diff. A change during a pass asks for one more instead of cancelling it, which would
    /// leave rows showing a cancelled git call as a problem.
    private func refreshRowsAfterRefs() {
        if rowRefresh != nil {
            rowRefreshPending = true
            return
        }
        rowRefresh = Task { [weak self] in
            repeat {
                self?.rowRefreshPending = false
                await self?.refreshRows(skippingSelected: true)
            } while self?.rowRefreshPending == true && self?.isClosed == false
            self?.rowRefresh = nil
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
    package func close() {
        if let anchor = diff.anchor { selected?.savedAnchor = anchor }
        persist()
        isClosed = true
        monitorTask?.cancel()
        monitorTask = nil
        threads?.stop()
        pullRequestThreads?.stop()
        pullRequests?.stop()
        rowsTask?.cancel()
        rowRefresh?.cancel()
        for task in deferredActivity.values { task.cancel() }
        selected?.cancelLoading()
    }

    var isWatching: Bool { monitorTask != nil }

    /// An open request (`seam`, a drop, Open Recent). A worktree created since the list was read
    /// isn't in it yet, so the list is read again first; the base applies only if that worktree
    /// really got selected.
    package func handle(worktree: String, base: String?) async {
        if !reviews.contains(where: { $0.id == worktree }) { await relistWorktrees() }
        select(worktree)
        guard selectedID == worktree, let base else { return }
        await setTypedBase(base)
    }

    /// The diff scrolled to another file. Saving here, not only on switch or close, keeps the
    /// position across ⌘Q, where nothing else gets a chance to run.
    package func noteReading(_ path: String?) {
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

    package func recentRepositories() async -> [URL] {
        await services.store.recentRepositories()
    }

    /// Waits for every row's detection and counts.
    func rowsLoaded() async {
        await rowsTask?.value
    }

    /// Waits for in-flight work; tests use it instead of sleeping.
    func settled() async {
        await reloadTask?.value
        await selected?.loaded()
        await rowsTask?.value
        await rowRefresh?.value
        await pullRequests?.idle()
        while let save = saveTask { await save.value }
        await keepingSeen?.value
    }
}
