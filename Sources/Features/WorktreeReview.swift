import DiffView
import Foundation
import GitKit
import Highlighting
import Observation
import SeamCore
import os

/// One worktree's row data and review state (SPEC §7.2–7.4). Owned by `RepoSession`.
@MainActor
@Observable
final class WorktreeReview: Identifiable {
    enum Problem: Equatable, Sendable {
        case missingDirectory
        case overrideGone(String)
        case gitFailed(String)
        case editorFailed(String)
    }

    let id: String
    private(set) var worktree: Worktree
    private(set) var detection: BaseDetection?
    private(set) var activity: WorktreeActivity?
    /// The parent ref chosen in the base picker, overriding detection (SPEC §5.3).
    private(set) var baseOverride: String?
    private(set) var scope = ReviewScope.all
    private(set) var mode: DiffLayoutMode
    private(set) var collapsed: Set<String> = []
    private(set) var wraps = false
    /// Files marked viewed, by path (SPEC §11).
    private(set) var viewed = ViewedMarks()
    /// A detected parent that looks merged (SPEC §5.4); nil once dismissed or overridden.
    private(set) var staleParent: StaleParent?
    /// The worktree's root `.editorconfig`, for per-file tab widths (SPEC §12).
    private var editorConfig: EditorConfig?
    private var dismissedStaleParents: Set<String> = []
    /// Full file contents for the current diff; empty until loaded.
    private(set) var contents: [String: FileContents] = [:]
    private(set) var contentsVersion = 0
    private(set) var syntax: [String: FileSyntax] = [:]
    private(set) var syntaxVersion = 0
    private var highlightTask: Task<Void, Never>?
    private var openedByReader: Set<String> = []
    /// Whether the file list's "Generated" group is open.
    var showsGenerated = false
    /// Revealed context per file and gap. Kept across reloads; gaps that moved simply reset.
    private(set) var expansions: [String: [Int: GapExpansion]] = [:]
    private(set) var diff: ReviewDiff?
    /// Bumped on every new diff, so the view knows to redraw even when the content is equal.
    private(set) var diffVersion = 0
    private(set) var isLoading = false
    /// Turns on only once a load has taken 150 ms, so fast loads don't flicker (SPEC §9).
    private(set) var showsProgress = false
    private(set) var problem: Problem?
    /// The file the diff is scrolled to; the file list follows it.
    var currentFile: String?
    /// Where the reader was when they last left this worktree.
    var savedAnchor: ScrollAnchor?
    var fileFilter = ""
    var flatFileList = false
    var collapsedDirectories: Set<String> = []

    private let services: SeamServices
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "Features")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "Features")

    init(worktree: Worktree, mode: DiffLayoutMode, services: SeamServices) {
        id = worktree.id
        self.worktree = worktree
        self.mode = mode
        self.services = services
    }

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
    private var lastEvent: Date?
    private var overrideCommitCount: Int?

    func noteChange(at date: Date) {
        lastEvent = date
    }

    func update(_ worktree: Worktree) {
        self.worktree = worktree
    }

    func restore(_ state: RepoState.WorktreeState?, override: String?) {
        if let scope = state?.scope.flatMap(ReviewScope.init) { self.scope = scope }
        if let mode = state?.mode.flatMap(DiffLayoutMode.init) { self.mode = mode }
        if let wraps = state?.wraps { self.wraps = wraps }
        if let viewed = state?.viewed { self.viewed = viewed }
        savedAnchor = state?.anchor
        currentFile = state?.currentFile
        baseOverride = override
    }

    var persistentState: RepoState.WorktreeState {
        RepoState.WorktreeState(
            scope: scope.rawValue, mode: mode.rawValue, wraps: wraps, viewed: viewed,
            anchor: savedAnchor, currentFile: currentFile)
    }

    // MARK: - Intents

    func setScope(_ scope: ReviewScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        reloadDiff()
    }

    func setMode(_ mode: DiffLayoutMode) {
        self.mode = mode
    }

    func toggleWrap() {
        wraps.toggle()
    }

    /// Returns the mark the file had before, for undo; nil when there's no such file.
    func toggleViewed(_ path: String) -> String?? {
        guard let file = diff?.files.first(where: { $0.diff.path == path }) else { return nil }
        let previous = viewed.marks[path]
        viewed.toggle(file)
        return .some(previous)
    }

    func restoreViewed(_ mark: String?, for path: String) {
        viewed.setMark(mark, for: path)
    }

    /// Where "open in editor" lands for a whole file: its first hunk's first new line.
    func firstChangedLine(of path: String) -> Int {
        guard let hunk = diff?.files.first(where: { $0.diff.path == path })?.diff.hunks.first
        else { return 1 }
        return max(hunk.newStart, 1)
    }

    func viewedStatus(_ path: String) -> ViewedMarks.Status {
        diff?.files.first { $0.diff.path == path }.map(viewed.status) ?? .unviewed
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
        reloadDiff()
    }

    func toggleCollapsed(_ path: String) {
        if collapsed.remove(path) == nil {
            collapsed.insert(path)
            openedByReader.remove(path)
        } else {
            openedByReader.insert(path)
        }
    }

    /// Generated and large files start collapsed, except ones the reader has opened.
    private func applyDefaultCollapse(_ diff: ReviewDiff) {
        for file in diff.files
        where file.startsCollapsed && !openedByReader.contains(file.diff.path) {
            collapsed.insert(file.diff.path)
        }
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

    /// What the diff view shows; nil until the diff has loaded.
    var content: DiffContent? {
        diff.map {
            DiffContent(
                review: $0, mode: mode, collapsed: collapsed, contents: contents,
                expansions: expansions, syntax: syntax, wraps: wraps,
                viewed: Dictionary(
                    $0.files.map { ($0.diff.path, viewed.status(of: $0)) },
                    uniquingKeysWith: { first, _ in first }),
                tabWidth: services.settings.tabWidth,
                tabWidths: Dictionary(
                    $0.files.compactMap { file in
                        editorConfig?.tabWidth(for: file.diff.path).map { (file.diff.path, $0) }
                    }, uniquingKeysWith: { first, _ in first }))
        }
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

    func refreshActivity() async {
        guard !worktree.isMissing else { return }
        do {
            activity = try await WorktreeActivityService(
                git: services.git, fileSystem: services.fileSystem
            ).activity(of: worktree.path)
        } catch {
            logger.error("status failed for \(self.id, privacy: .public): \(error)")
        }
    }

    /// `refs` comes from the session when it refreshes every row at once.
    func refreshDetection(refs: RefSnapshot? = nil) async {
        guard !worktree.isMissing else {
            problem = .missingDirectory
            return
        }
        do {
            detection = try await BaseDetector(
                git: services.git, settings: services.settings.detection
            )
            .detect(in: worktree.path, refs: refs)
        } catch {
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
        staleParent = nil
    }

    func report(_ problem: Problem) {
        self.problem = problem
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
                problem = baseOverride.map { .overrideGone(RefName.short($0)) }
                finish(generation)
                return
            }
            overrideCommitCount = base.commitCount
            let stale =
                baseOverride == nil
                ? try await StaleParent.check(detection, in: worktree.path, git: services.git)
                : nil
            guard generation == loadGeneration else { return }
            staleParent = stale.flatMap { dismissedStaleParents.contains($0.parent) ? nil : $0 }
            let result = try await ReviewDiffBuilder(
                git: services.git, fileSystem: services.fileSystem
            ).build(
                worktree: worktree.path, base: base.commit, scope: scope,
                options: services.settings.diffOptions)
            editorConfig =
                (try? services.fileSystem.contents(
                    of: worktree.path.appending(path: ".editorconfig")))
                .map { EditorConfig(String(decoding: $0, as: UTF8.self)) }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // A first load shows the diff before its contents arrive. A reload waits for both,
            // so the new hunks are never drawn with the old files' gap lines.
            let isReload = !contents.isEmpty
            if !isReload { present(result) }
            let loaded = try await FileContentLoader(
                git: services.git, fileSystem: services.fileSystem
            ).load(result, worktree: worktree.path)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if isReload { present(result) }
            // Spans of files whose text changed would paint the new lines wrongly until redone.
            let previous = contents
            syntax = syntax.filter { previous[$0.key] == loaded[$0.key] }
            contents = loaded
            contentsVersion += 1
            highlight(result, loaded)
        } catch {
            guard generation == loadGeneration, error != .cancelled else { return }
            problem = .gitFailed(Self.describe(error))
        }
        finish(generation)
    }

    private func present(_ diff: ReviewDiff) {
        applyDefaultCollapse(diff)
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
