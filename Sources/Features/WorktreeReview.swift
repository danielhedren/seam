import DiffView
import Foundation
import GitKit
import Observation
import SeamCore
import os

/// One worktree's row data and review state (SPEC §7.2–7.4). Owned by `RepoSession`.
@MainActor
@Observable
public final class WorktreeReview: Identifiable {
    public enum Problem: Equatable, Sendable {
        case missingDirectory
        case overrideGone(String)
        case gitFailed(String)
    }

    public let id: String
    public private(set) var worktree: Worktree
    public private(set) var detection: BaseDetection?
    public private(set) var activity: WorktreeActivity?
    /// The parent ref chosen in the base picker, overriding detection (SPEC §5.3).
    public private(set) var baseOverride: String?
    public private(set) var scope = ReviewScope.all
    public private(set) var mode: DiffLayoutMode
    public private(set) var collapsed: Set<String> = []
    public private(set) var diff: ReviewDiff?
    /// Bumped on every new diff, so the view knows to redraw even when the content is equal.
    public private(set) var diffVersion = 0
    public private(set) var isLoading = false
    /// Turns on only once a load has taken 150 ms, so fast loads don't flicker (SPEC §9).
    public private(set) var showsProgress = false
    public private(set) var problem: Problem?
    /// The file the diff is scrolled to; the file list follows it.
    public var currentFile: String?
    /// Where the reader was when they last left this worktree.
    public var savedAnchor: ScrollAnchor?
    public var fileFilter = ""
    public var flatFileList = false
    public var collapsedDirectories: Set<String> = []

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
    public var parentName: String? {
        baseOverride.map(RefDisplay.short) ?? detection?.parent?.name
    }

    public var uniqueCommitCount: Int? {
        guard let detection else { return nil }
        guard let baseOverride else { return detection.uniqueCommitCount }
        return detection.candidates.first { $0.ref == baseOverride }?.commitCount
    }

    public var lastChange: Date? { activity?.lastChange }

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
        if collapsed.remove(path) == nil { collapsed.insert(path) }
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
            }
            let result = try await ReviewDiffBuilder(
                git: services.git, fileSystem: services.fileSystem
            ).build(worktree: worktree.path, base: base, scope: scope)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            diff = result
            diffVersion += 1
            problem = nil
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
        case .launchFailed(let message): message
        case .nonZeroExit(let arguments, _, let stderr):
            "git \(arguments.first ?? "") failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .cancelled: "cancelled"
        case .unexpectedOutput(let message): message
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
