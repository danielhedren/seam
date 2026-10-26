import DiffView
import Foundation
import GitKit
import Highlighting
import Observation
import SeamCore

/// One worktree's row data and review state (SPEC §7.2–7.4). Owned by `RepoSession`.
@MainActor
@Observable
final class WorktreeReview: Identifiable {
    enum Problem: Equatable, Sendable {
        case missingDirectory
        case overrideGone(String)
        case gitFailed(String)
        case editorFailed(String)
        /// The version of this file the reader marked viewed is no longer to be had.
        case seenGone(String)
    }

    let id: String
    private(set) var worktree: Worktree
    private(set) var detection: BaseDetection?
    private(set) var activity: WorktreeActivity?
    /// The parent ref chosen in the base picker, overriding detection (SPEC §5.3).
    private(set) var baseOverride: String?
    private(set) var scope = ReviewScope.all
    /// Commits picked in the commit list, in place of `scope` until a scope is picked again.
    private(set) var commitSelection: CommitSelection?
    private(set) var commitLog: CommitLog?
    private var collapse = CollapseState()
    var collapsed: Set<String> { collapse.collapsed }
    private(set) var wraps = false
    /// Starts from the setting; Review › Hide Whitespace Changes flips it for this worktree.
    private(set) var whitespace: WhitespaceMode?

    var effectiveWhitespace: WhitespaceMode { whitespace ?? services.settings.whitespace }

    private var diffOptions: DiffOptions {
        var options = services.settings.diffOptions
        options.whitespace = effectiveWhitespace
        return options
    }
    /// Files marked viewed, by path (SPEC §11).
    private(set) var viewed = ViewedMarks()
    /// Files shown as their change since viewed, by path: the text the reader saw (SPEC §7.4).
    private(set) var sinceViewed: [String: String] = [:]
    /// Worked out when the files or the choice change, not on every redraw.
    private var sinceViewedDiffs: [String: FileDiff] = [:]
    /// What the git checks found (SPEC §5.4); `staleParent` adds the pull request's word.
    private var checkedStaleParent: StaleParent?
    /// The worktree's root `.editorconfig`, for per-file tab widths (SPEC §12).
    private var editorConfig: EditorConfig?
    private var tabWidths: [String: Int] = [:]
    private var dismissedStaleParents: Set<String> = []
    private var dismissedPullRequestBases: Set<String> = []
    private var lastEvent: Date?
    private var overrideCommitCount: Int?
    /// The chosen parent's merge base, once a load has resolved it.
    private var overrideBase: String?
    private var activityBase: String?
    private var detectionRuns = 0
    private var activityRuns = 0
    private var staleCheckedAt = -1
    /// Full file contents for the current diff; empty until loaded.
    private(set) var contents: [String: FileContents] = [:]
    private(set) var contentsVersion = 0
    private(set) var syntax: [String: FileSyntax] = [:]
    private(set) var syntaxVersion = 0
    private var highlightTask: Task<Void, Never>?
    /// Whether the file list's "Generated" group is open.
    var showsGenerated = false
    /// Revealed context per file and gap. Kept across reloads; gaps that moved simply reset.
    private(set) var expansions: [String: [Int: GapExpansion]] = [:]
    private(set) var diff: ReviewDiff?
    /// Bumped on every new diff, so the view knows to redraw even when the content is equal.
    private(set) var diffVersion = 0
    /// Bumped when the reader picks another range (scope, commits or parent); the shown diff
    /// carries the one it was built for, and a new range starts at the top.
    private var rangeVersion = 0
    private(set) var shownRangeVersion = 0
    private(set) var isLoading = false
    /// Turns on only once a load has taken 150 ms, so fast loads don't flicker (SPEC §9).
    private(set) var showsProgress = false
    private(set) var problem: Problem?
    /// The file the diff is scrolled to; the file list follows it.
    var currentFile: String?
    /// Where the reader was when they last left this worktree.
    var savedAnchor: ScrollAnchor?
    var fileFilter = "" {
        didSet { scheduleDiffFilter() }
    }
    /// The filter the diff shows; it follows `fileFilter` once typing pauses, so the diff isn't
    /// rebuilt on every keystroke. Clearing applies at once.
    private(set) var diffFilter = ""
    private var filterTask: Task<Void, Never>?
    var flatFileList = false
    var collapsedDirectories: Set<String> = []
    /// Files or Search in the file list's column (SPEC §7.3.1).
    var navigator = Navigator.files
    var search = TextQuery() {
        didSet {
            guard search != oldValue else { return }
            searchFoldToggles = []
            scheduleSearch()
        }
    }
    /// The query the results and the diff show; it follows `search` as `diffFilter` follows
    /// `fileFilter`.
    private(set) var appliedSearch = TextQuery()
    private var searchTask: Task<Void, Never>?
    /// Result files whose fold the reader flipped from the default.
    var searchFoldToggles: Set<String> = []
    var selectedSearchRow: String?
    @ObservationIgnored let searchCache = SearchCache()

    /// The repo's threads; this worktree's are placed on its diff (SPEC §7.7).
    var threads: RepoThreads?
    /// The repo's pull requests' threads, placed beside Seam's (SPEC §7.9).
    var pullRequestThreads: PullRequestThreads?
    /// The repo's pull requests; this worktree's branch's is its row's (SPEC §7.8).
    var pullRequests: RepoPullRequests?
    @ObservationIgnored let placementCache = ThreadPlacementCache()
    @ObservationIgnored let fileListCache = FileListCache()

    let services: SeamServices
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    init(worktree: Worktree, services: SeamServices) {
        id = worktree.id
        self.worktree = worktree
        self.services = services
    }

    var mode: DiffLayoutMode { services.settings.layoutMode }

    /// The parent the diff is against: the override if set, else the detected one.
    var parentName: String? {
        baseOverride.map(RefName.short) ?? detection?.parent?.name
    }

    var uniqueCommitCount: Int? {
        guard let detection else { return nil }
        guard let baseOverride else { return detection.uniqueCommitCount }
        return detection.candidates.first { $0.ref == baseOverride }?.commitCount
            ?? overrideCommitCount
    }

    /// The newest of the status-derived time and the last watcher event (SPEC §7.2).
    var lastChange: Date? {
        [activity?.lastChange, lastEvent].compactMap(\.self).max()
    }

    /// Changes against the base, uncommitted files or an open pull request: work to review.
    var hasWork: Bool {
        (activity?.changes?.files ?? 0) > 0 || (activity?.uncommittedFiles ?? 0) > 0
            || pullRequest?.state == .open
    }

    /// What the row's totals are measured from: the same base the diff uses.
    private var statsBase: String? {
        baseOverride == nil ? detection?.base : overrideBase
    }

    func noteChange(at date: Date) {
        lastEvent = date
    }

    func update(_ worktree: Worktree) {
        self.worktree = worktree
    }

    func restore(_ state: RepoState.WorktreeState?, override: String?) {
        if let scope = state?.scope.flatMap(ReviewScope.init) { self.scope = scope }
        if let wraps = state?.wraps { self.wraps = wraps }
        whitespace = state?.whitespace.flatMap(WhitespaceMode.init)
        if let viewed = state?.viewed { self.viewed = viewed }
        dismissedStaleParents = Set(state?.dismissedStaleParents ?? [])
        dismissedPullRequestBases = Set(state?.dismissedPullRequestBases ?? [])
        savedAnchor = state?.anchor
        currentFile = state?.currentFile
        baseOverride = override
    }

    var persistentState: RepoState.WorktreeState {
        RepoState.WorktreeState(
            scope: scope.rawValue, wraps: wraps,
            whitespace: whitespace?.rawValue, viewed: viewed,
            dismissedStaleParents: dismissedStaleParents.isEmpty
                ? nil : dismissedStaleParents.sorted(),
            dismissedPullRequestBases: dismissedPullRequestBases.isEmpty
                ? nil : dismissedPullRequestBases.sorted(),
            anchor: savedAnchor, currentFile: currentFile)
    }

    // MARK: - Intents

    func setScope(_ scope: ReviewScope) {
        guard scope != self.scope || commitSelection != nil else { return }
        self.scope = scope
        commitSelection = nil
        rangeVersion += 1
        reloadDiff()
    }

    /// The commit list's highlighted rows: the picked commits, or the ones the scope covers.
    var shownSelection: CommitSelection? {
        commitSelection ?? commitLog?.selection(for: scope)
    }

    func selectCommits(_ selection: CommitSelection) {
        guard selection != shownSelection, let log = commitLog else { return }
        if let scope = log.scope(matching: selection) {
            setScope(scope)
            return
        }
        commitSelection = selection
        rangeVersion += 1
        reloadDiff()
    }

    /// What the diff leaves out, said where the reader is: nil while it shows every change.
    var rangeSummary: String? {
        var parts: [String] = []
        if let selection = commitSelection, let commits = commitLog?.commits {
            if selection.newest == selection.oldest, case .commit(let id) = selection.newest,
                let index = commits.firstIndex(where: { $0.id == id })
            {
                let number = commits.count - index
                parts.append(
                    String(
                        localized:
                            "Commit \(number) of \(commits.count) · \(commits[index].subject)",
                        bundle: .module))
            } else if let ends = commitLog?.ends,
                let newest = ends.firstIndex(of: selection.newest),
                let oldest = ends.firstIndex(of: selection.oldest), newest <= oldest
            {
                let range = ends[newest...oldest]
                let picked = range.count { if case .commit = $0 { true } else { false } }
                parts.append(
                    range.contains(.workingTree)
                        ? String(
                            localized: "\(picked) commits and uncommitted changes", bundle: .module)
                        : String(localized: "\(picked) commits", bundle: .module))
            }
        } else if scope == .committed {
            parts.append(String(localized: "Committed changes only", bundle: .module))
        } else if scope == .uncommitted {
            parts.append(String(localized: "Uncommitted changes only", bundle: .module))
        }
        if effectiveWhitespace != .show {
            parts.append(String(localized: "Whitespace changes hidden", bundle: .module))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The range bar's Show All: every change, whitespace included.
    func showEverything() {
        if effectiveWhitespace != .show { toggleWhitespace() }
        setScope(.all)
    }

    /// The one commit Go › Next Commit (later in time) or Previous Commit would show, reading a
    /// branch commit by commit; from no single commit, Next starts at the oldest. Nil at an end.
    func commitStep(by delta: Int) -> CommitSelection? {
        guard let commits = commitLog?.commits, !commits.isEmpty else { return nil }
        // Listed newest first, so later in time is up the list.
        let index: Int
        if let selection = commitSelection, selection.newest == selection.oldest,
            case .commit(let id) = selection.newest,
            let current = commits.firstIndex(where: { $0.id == id })
        {
            index = current - delta
        } else {
            index = delta > 0 ? commits.count - 1 : 0
        }
        guard commits.indices.contains(index) else { return nil }
        let end = CommitSelection.End.commit(commits[index].id)
        return CommitSelection(newest: end, oldest: end)
    }

    func stepCommit(by delta: Int) {
        if let step = commitStep(by: delta) { selectCommits(step) }
    }

    func isShowing(_ scope: ReviewScope) -> Bool {
        commitSelection == nil && self.scope == scope
    }

    var isShowingLatestCommit: Bool {
        guard let latest = commitLog?.commits.first else { return false }
        return commitSelection
            == CommitSelection(newest: .commit(latest.id), oldest: .commit(latest.id))
    }

    /// Only the newest commit; nothing to do on a branch with no commits of its own.
    func selectLatestCommit() {
        guard let latest = commitLog?.commits.first else { return }
        selectCommits(CommitSelection(newest: .commit(latest.id), oldest: .commit(latest.id)))
    }

    func toggleWrap() {
        wraps.toggle()
    }

    /// Between showing whitespace and the configured way of hiding it (all of it, by default).
    func toggleWhitespace() {
        let hidden =
            services.settings.whitespace == .show ? .ignoreAll : services.settings.whitespace
        whitespace = effectiveWhitespace == .show ? hidden : .show
        reloadDiff()
    }

    private func file(_ path: String) -> ReviewFile? {
        diff?.files.first { $0.diff.path == path }
    }

    /// Returns the mark the file had before, for undo; nil when there's no such file.
    func toggleViewed(_ path: String) -> String?? {
        guard let file = file(path) else { return nil }
        let previous = viewed.marks[path]
        viewed.toggle(file)
        collapseIfViewed(path)
        refreshSinceViewed()
        return .some(previous)
    }

    func restoreViewed(_ mark: String?, for path: String) {
        viewed.setMark(mark, for: path)
        collapseIfViewed(path)
        refreshSinceViewed()
    }

    /// The file's text as the reader saw it and the id to keep it by, right after marking it.
    func seenText(_ path: String) -> (id: String, text: String)? {
        guard let file = file(path), let text = contents[path]?.new,
            let id = viewed.seen(file, text: text)
        else { return nil }
        return (id, text)
    }

    /// The mark's content id, when the file has changed since and its text now is loaded.
    func sinceViewedID(_ path: String) -> String? {
        guard viewedStatus(path) == .changedSinceViewed, contents[path]?.new != nil,
            let id = viewed.marks[path], !id.hasPrefix("deleted:")
        else { return nil }
        return id
    }

    func showSinceViewed(_ path: String, seen text: String) {
        sinceViewed[path] = text
        expansions[path] = nil
        refreshSinceViewed()
    }

    func showFullDiff(_ path: String) {
        sinceViewed[path] = nil
        expansions[path] = nil
        refreshSinceViewed()
    }

    /// A file viewed again, or no longer changed, goes back to its full diff.
    private func refreshSinceViewed() {
        var diffs: [String: FileDiff] = [:]
        for (path, seen) in sinceViewed {
            guard let file = file(path), viewed.status(of: file) == .changedSinceViewed,
                let now = contents[path]?.new
            else {
                sinceViewed[path] = nil
                expansions[path] = nil
                continue
            }
            diffs[path] =
                sinceViewedDiffs[path].flatMap { $0.newBlob == file.diff.newBlob ? $0 : nil }
                ?? SinceViewed.diff(file.diff, from: seen, to: now)
        }
        sinceViewedDiffs = diffs
    }

    private func collapseIfViewed(_ path: String) {
        guard let file = file(path) else { return }
        collapse.viewedChanged(
            path, to: viewed.status(of: file),
            collapsesViewed: services.settings.collapsesViewed)
    }

    /// Where "open in editor" lands for a whole file: its first hunk's first new line.
    func firstChangedLine(of path: String) -> Int {
        guard let hunk = file(path)?.diff.hunks.first else { return 1 }
        return max(hunk.newStart, 1)
    }

    func viewedStatus(_ path: String) -> ViewedMarks.Status {
        file(path).map(viewed.status) ?? .unviewed
    }

    /// The next file after `path`, in review order and wrapping, that isn't viewed.
    func nextUnviewed(after path: String?) -> String? {
        guard let files = diff?.files, !files.isEmpty else { return nil }
        let start = files.firstIndex { $0.diff.path == path } ?? -1
        return (1...files.count).lazy
            .map { files[(start + $0 + files.count) % files.count] }
            .first { viewed.status(of: $0) != .viewed }?.diff.path
    }

    func setOverride(_ ref: String?) {
        let ref = ref == detection?.parent?.ref ? nil : ref
        guard ref != baseOverride else { return }
        baseOverride = ref
        rangeVersion += 1
        reloadDiff()
    }

    func toggleCollapsed(_ path: String) {
        collapse.toggle(path)
    }

    private func applyDefaultCollapse(_ diff: ReviewDiff) {
        collapse.load(
            diff.files.map {
                CollapseState.File(
                    path: $0.diff.path, startsCollapsed: $0.startsCollapsed,
                    status: viewed.status(of: $0))
            }, collapsesViewed: services.settings.collapsesViewed)
    }

    func expand(_ path: String, gap: Int, _ direction: ExpandDirection) {
        var expansion = expansions[path]?[gap] ?? GapExpansion()
        switch direction {
        case .down: expansion.top += DiffContent.expandStep
        case .up: expansion.bottom += DiffContent.expandStep
        case .all: expansion = .all
        }
        expansions[path, default: [:]][gap] = expansion
    }

    static let filterDelay = Duration.milliseconds(300)

    private func scheduleDiffFilter() {
        filterTask?.cancel()
        guard !fileFilter.isEmpty else {
            diffFilter = ""
            return
        }
        let clock = services.clock
        filterTask = Task { [weak self] in
            try? await clock.sleep(for: Self.filterDelay)
            guard !Task.isCancelled, let self else { return }
            self.diffFilter = self.fileFilter
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        // Only the text waits for typing to pause; an empty field or a flipped toggle applies now.
        guard !search.isEmpty, search.text != appliedSearch.text else {
            appliedSearch = search
            return
        }
        let clock = services.clock
        searchTask = Task { [weak self] in
            try? await clock.sleep(for: Self.filterDelay)
            guard !Task.isCancelled, let self else { return }
            self.appliedSearch = self.search
        }
    }

    /// How the diff is narrowed: by the filter, or while Search shows a query, by its results.
    var narrowing: Narrowing {
        isSearching ? .search(appliedSearch) : .filter(diffFilter)
    }

    /// What the diff view shows, narrowed; nil until the diff has loaded.
    var content: DiffContent? {
        let filter = FileFilter(diffFilter)
        let found = searchResult.map { Set($0.files.map(\.index)) }
        return diff.map { diff in
            if isSearching {
                return ReviewDiff(
                    scope: diff.scope,
                    files: diff.files.indices.filter { found?.contains($0) == true }.map {
                        diff.files[$0]
                    })
            }
            return filter.isEmpty
                ? diff
                : ReviewDiff(
                    scope: diff.scope, files: diff.files.filter { filter.matches($0.diff.path) })
        }.map {
            DiffContent(
                review: $0, mode: mode, collapsed: collapsed, contents: contents,
                expansions: expansions, syntax: syntax, wraps: wraps,
                viewed: Dictionary(
                    $0.files.map { ($0.diff.path, viewed.status(of: $0)) },
                    uniquingKeysWith: { first, _ in first }),
                tabWidth: services.settings.tabWidth, tabWidths: tabWidths,
                threads: threadMarkers)
        }.map { content in
            var content = content
            content.resolvedMarks = hiddenResolvedMarkers
            return showingSinceViewed(content)
        }
    }

    /// The old side of a file shown since viewed is the text the reader saw, so the base's
    /// highlights and old-side threads don't belong on it.
    private func showingSinceViewed(_ content: DiffContent) -> DiffContent {
        guard !sinceViewedDiffs.isEmpty else { return content }
        var content = content
        content.review.files = content.review.files.map { file in
            guard let diff = sinceViewedDiffs[file.diff.path] else { return file }
            var file = file
            file.diff = diff
            return file
        }
        for (path, seen) in sinceViewed where sinceViewedDiffs[path] != nil {
            content.contents[path]?.old = seen
            content.syntax[path]?.old = nil
            content.syntax[path]?.oldScopes = []
            content.threads[path]?.removeAll { $0.side == .old }
            content.resolvedMarks[path]?.removeAll { $0.side == .old }
        }
        content.sinceViewed = Set(sinceViewedDiffs.keys)
        return content
    }

    private func highlight(_ diff: ReviewDiff, _ contents: [String: FileContents]) {
        highlightTask?.cancel()
        let pass = HighlightPass(
            files: diff.files, contents: contents, first: currentFile,
            highlighter: services.highlighter)
        highlightTask = Task { [weak self] in
            await pass.run { batch in
                guard let self else { return }
                self.syntax.merge(batch) { $1 }
                self.syntaxVersion += 1
            }
        }
    }

    /// Waits for highlighting; tests use it instead of sleeping.
    func highlighted() async {
        await highlightTask?.value
    }

    // MARK: - Loading

    /// Counts can overlap like detection, so only the most recently started one is kept.
    func refreshActivity() async {
        guard !worktree.isMissing else { return }
        let base = statsBase
        activityRuns += 1
        let run = activityRuns
        do {
            let read = try await WorktreeActivityService(
                git: services.git, fileSystem: services.fileSystem
            ).activity(of: worktree.path, base: base)
            guard run == activityRuns else { return }
            activity = read
            activityBase = base
        } catch {
            logger.error("status failed for \(self.id, privacy: .public): \(error)")
        }
    }

    /// `refs` comes from the session when it refreshes every row at once. Refreshes can overlap
    /// (the monitor and a reload), so only the most recently started one may write its result:
    /// it saw the newest refs.
    func refreshDetection(refs: RefSnapshot? = nil) async {
        guard !worktree.isMissing else {
            problem = .missingDirectory
            return
        }
        detectionRuns += 1
        let run = detectionRuns
        do {
            let result = try await BaseDetector(
                git: services.git, settings: services.settings.detection
            )
            .detect(in: worktree.path, refs: refs)
            guard run == detectionRuns else { return }
            detection = result
        } catch {
            guard run == detectionRuns else { return }
            problem = .gitFailed(Self.describe(error))
        }
    }

    /// Recomputes the diff, cancelling any load still in flight for this worktree.
    func reloadDiff() {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        guard !worktree.isMissing else {
            problem = .missingDirectory
            diff = nil
            isLoading = false
            showsProgress = false
            return
        }
        isLoading = true
        let clock = services.clock
        let progress = Task { [weak self] in
            try? await clock.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
            self.showsProgress = self.isLoading
        }
        loadTask = Task { [weak self] in
            await self?.load(generation)
            progress.cancel()
        }
    }

    /// Waits for the current load; tests use it instead of sleeping.
    func loaded() async {
        await loadTask?.value
    }

    func dismissStaleParent() {
        if let parent = staleParent?.parent { dismissedStaleParents.insert(parent) }
    }

    /// A detected parent that looks merged (SPEC §5.4), by git's evidence or because its own
    /// pull request merged; nil once dismissed or overridden.
    var staleParent: StaleParent? {
        guard baseOverride == nil else { return nil }
        let stale = checkedStaleParent ?? mergedParentPullRequest
        return stale.flatMap { dismissedStaleParents.contains($0.parent) ? nil : $0 }
    }

    private var mergedParentPullRequest: StaleParent? {
        guard let detection, let parent = detection.parent, parent.ref.hasPrefix(RefName.heads),
            let pullRequest = pullRequests?.pullRequest(for: RefName.shortBranch(parent.ref)),
            pullRequest.state == .merged
        else { return nil }
        return StaleParent.pullRequestMerged(detection, number: pullRequest.number)
    }

    var pullRequest: PullRequest? {
        pullRequests?.pullRequest(for: worktree.branch)
    }

    /// Commits on this branch its pull request doesn't have yet.
    var unpushedCount: Int? {
        guard pullRequest != nil, let branch = worktree.branch else { return nil }
        return pullRequests?.unpushedCount(for: branch)
    }

    /// An open PR's base, offered when it isn't the parent the diff is against (SPEC §7.8):
    /// the full ref here, and its short name. Not while the stale-parent banner already asks.
    var pullRequestBase: (ref: String, name: String)? {
        guard baseOverride == nil, staleParent == nil, let pullRequest,
            pullRequest.state == .open, let branch = worktree.branch,
            let ref = pullRequests?.baseRef(for: branch), let parent = detection?.parent,
            ref != parent.ref, Self.branchName(ref) != Self.branchName(parent.ref),
            !dismissedPullRequestBases.contains(ref)
        else { return nil }
        return (ref, RefName.short(ref))
    }

    func dismissPullRequestBase() {
        if let ref = pullRequestBase?.ref { dismissedPullRequestBases.insert(ref) }
    }

    /// `main` for `refs/heads/main` and `refs/remotes/origin/main` alike.
    private static func branchName(_ ref: String) -> String {
        if ref.hasPrefix(RefName.remotes) {
            return String(RefName.short(ref).drop { $0 != "/" }.dropFirst())
        }
        return RefName.short(ref)
    }

    /// Runs once per detection, which reruns on every ref change: a fetch that prunes the parent
    /// leaves detection's answer the same, so the result can't be compared instead. Working-tree
    /// reloads skip it. A failure leaves the banner off rather than failing the load.
    private func checkStaleParent(_ detection: BaseDetection) async {
        guard baseOverride == nil else { return }
        guard detectionRuns != staleCheckedAt else { return }
        let stale = try? await StaleParent.check(detection, in: worktree.path, git: services.git)
        staleCheckedAt = detectionRuns
        checkedStaleParent = stale ?? nil
    }

    func report(_ problem: Problem) {
        self.problem = problem
    }

    /// Only the notices: the others describe the diff and clear when it loads again.
    func dismissNotice() {
        switch problem {
        case .editorFailed, .seenGone: problem = nil
        default: break
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        highlightTask?.cancel()
        loadGeneration += 1
        isLoading = false
        showsProgress = false
    }

    private func load(_ generation: Int) async {
        let interval = signposter.beginInterval("loadDiff")
        defer { signposter.endInterval("loadDiff", interval) }
        let rangeVersion = rangeVersion
        if detection == nil { await refreshDetection() }
        guard generation == loadGeneration, let detection else {
            finish(generation)
            return
        }
        do {
            guard
                let base = try await ReviewBase.resolve(
                    detection: detection, override: baseOverride, in: worktree.path,
                    git: services.git)
            else {
                guard generation == loadGeneration else { return }
                overrideCommitCount = nil
                overrideBase = nil
                if statsBase != activityBase { await refreshActivity() }
                guard generation == loadGeneration else { return }
                problem = baseOverride.map { .overrideGone(RefName.short($0)) }
                finish(generation)
                return
            }
            guard generation == loadGeneration else { return }
            overrideCommitCount = base.commitCount
            overrideBase = baseOverride == nil ? nil : base.commit
            // Another parent, or detection's first answer, moves the row's totals too.
            if statsBase != activityBase { await refreshActivity() }
            await checkStaleParent(detection)
            let loader = ReviewLoader(git: services.git, fileSystem: services.fileSystem)
            let log = try await loader.commits(from: base.commit, in: worktree.path)
            guard generation == loadGeneration else { return }
            commitLog = log
            let loadedDiff = try await loader.diff(
                log, from: base.commit, in: worktree.path, selection: commitSelection,
                scope: scope, options: diffOptions)
            guard generation == loadGeneration else { return }
            // Picked commits a rebase or reset removed fall back to the scope.
            commitSelection = loadedDiff.selection
            let result = loadedDiff.diff
            let config = await loader.editorConfig(in: worktree.path)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            editorConfig = config
            // A first load shows the diff before its contents arrive. A reload waits for both,
            // so the new hunks are never drawn with the old files' gap lines.
            let isReload = !contents.isEmpty
            if !isReload { present(result, rangeVersion) }
            let loaded = try await loader.contents(of: result, in: worktree.path)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if isReload { present(result, rangeVersion) }
            // Spans of files whose text changed would paint the new lines wrongly until redone.
            let previous = contents
            syntax = syntax.filter { previous[$0.key] == loaded[$0.key] }
            contents = loaded
            contentsVersion += 1
            refreshSinceViewed()
            highlight(result, loaded)
        } catch {
            guard generation == loadGeneration, error != .cancelled else { return }
            problem = .gitFailed(Self.describe(error))
        }
        finish(generation)
    }

    private func present(_ diff: ReviewDiff, _ rangeVersion: Int) {
        shownRangeVersion = rangeVersion
        applyDefaultCollapse(diff)
        // Glob matching per file, so worked out once per diff rather than on every redraw.
        tabWidths = Dictionary(
            diff.files.compactMap { file in
                editorConfig?.tabWidth(for: file.diff.path).map { (file.diff.path, $0) }
            }, uniquingKeysWith: { first, _ in first })
        self.diff = diff
        diffVersion += 1
        problem = nil
    }

    private func finish(_ generation: Int) {
        guard generation == loadGeneration else { return }
        isLoading = false
        showsProgress = false
    }

    static func describe(_ error: GitError) -> String {
        switch error {
        case .launchFailed(let message):
            String(localized: "Couldn't run git: \(message)", bundle: .module)
        case .nonZeroExit(let arguments, _, let stderr):
            String(
                localized:
                    "git \(arguments.first ?? "") failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                bundle: .module)
        case .cancelled: String(localized: "Cancelled", bundle: .module)
        case .unexpectedOutput(let message):
            String(localized: "Unexpected output from git: \(message)", bundle: .module)
        }
    }
}
