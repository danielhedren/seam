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
        baseOverride.map(RefDisplay.short) ?? detection?.parent?.name
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
        baseOverride = override
    }

    var persistentState: RepoState.WorktreeState {
        RepoState.WorktreeState(scope: scope.rawValue, mode: mode.rawValue)
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
                expansions: expansions, syntax: syntax)
        }
    }

    /// Highlights every file off the main actor, the one being read first. Results publish after
    /// that file and then in batches, since each publish rebuilds the diff's rows.
    private func highlight(_ diff: ReviewDiff, _ contents: [String: FileContents]) {
        highlightTask?.cancel()
        let highlighter = services.highlighter
        let current = currentFile
        let files =
            diff.files.filter { $0.diff.path == current }
            + diff.files.filter { $0.diff.path != current }
        highlightTask = Task { [weak self] in
            var pending: [String: FileSyntax] = [:]
            for (index, file) in files.enumerated() {
                guard !Task.isCancelled else { return }
                let path = file.diff.path
                guard let texts = contents[path] else { continue }
                var result = FileSyntax()
                if let text = texts.old,
                    let language = SyntaxLanguage.detect(path: file.diff.oldPath ?? path)
                {
                    result.old = await highlighter.highlight(text, as: language)
                }
                if let text = texts.new, let language = SyntaxLanguage.detect(path: path) {
                    result.new = await highlighter.highlight(text, as: language)
                }
                if result.old != nil || result.new != nil { pending[path] = result }
                if index == 0 || index % 25 == 24 || index == files.count - 1, !pending.isEmpty {
                    guard let self, !Task.isCancelled else { return }
                    self.syntax.merge(pending) { $1 }
                    self.syntaxVersion += 1
                    pending = [:]
                }
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

    func refreshDetection() async {
        guard !worktree.isMissing else {
            problem = .missingDirectory
            return
        }
        do {
            detection = try await BaseDetector(git: services.git, settings: services.detection)
                .detect(in: worktree.path)
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
            var base = detection.base
            if let baseOverride {
                guard
                    let resolved = try await BaseDetector(git: services.git)
                        .base(forParent: baseOverride, in: worktree.path)
                else {
                    guard generation == loadGeneration else { return }
                    problem = .overrideGone(RefDisplay.short(baseOverride))
                    finish(generation)
                    return
                }
                base = resolved
                overrideCommitCount = try await BaseDetector(git: services.git)
                    .commitCount(since: resolved, in: worktree.path)
            }
            let result = try await ReviewDiffBuilder(
                git: services.git, fileSystem: services.fileSystem
            ).build(worktree: worktree.path, base: base, scope: scope)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            // A first load shows the diff before its contents arrive. A reload waits for both,
            // so the new hunks are never drawn with the old files' gap lines.
            let isReload = !contents.isEmpty
            if !isReload {
                applyDefaultCollapse(result)
                diff = result
                diffVersion += 1
                problem = nil
            }
            let loaded = try await FileContentLoader(
                git: services.git, fileSystem: services.fileSystem
            ).load(result, worktree: worktree.path)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if isReload {
                applyDefaultCollapse(result)
                diff = result
                diffVersion += 1
                problem = nil
            }
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

enum RefDisplay {
    static func short(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}
