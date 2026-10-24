import Foundation
import GitKit

// The app's per-repo state file (SPEC §11), read by `seam` too, so its shape lives here.

/// What Seam remembers per repo (SPEC §11).
public struct RepoState: Codable, Equatable, Sendable {
    public struct WorktreeState: Codable, Equatable, Sendable {
        public var scope: String?
        public var wraps: Bool?
        public var whitespace: String?
        public var viewed: ViewedMarks?
        /// Parents whose "looks merged" banner the reader dismissed.
        public var dismissedStaleParents: [String]?
        /// Pull request bases whose suggestion the reader dismissed, by full ref.
        public var dismissedPullRequestBases: [String]?
        /// Where the reader was, restored when the worktree is shown again.
        public var anchor: ScrollAnchor?
        public var currentFile: String?

        public init(
            scope: String? = nil, wraps: Bool? = nil, whitespace: String? = nil,
            viewed: ViewedMarks? = nil, dismissedStaleParents: [String]? = nil,
            dismissedPullRequestBases: [String]? = nil, anchor: ScrollAnchor? = nil,
            currentFile: String? = nil
        ) {
            self.scope = scope
            self.wraps = wraps
            self.whitespace = whitespace
            self.viewed = viewed
            self.dismissedStaleParents = dismissedStaleParents
            self.dismissedPullRequestBases = dismissedPullRequestBases
            self.anchor = anchor
            self.currentFile = currentFile
        }
    }

    /// Base override per branch: the chosen parent ref (SPEC §5.3).
    public var baseOverrides: [String: String] = [:]
    /// Keyed by worktree path.
    public var worktrees: [String: WorktreeState] = [:]
    /// The worktree the window last showed, selected again on reopen.
    public var selectedWorktree: String?
    /// The last pull requests read, shown at once on reopen (SPEC §7.8).
    public var pullRequests: SavedPullRequests?

    public init() {}
}

/// What Seam keeps of a repo's pull requests between launches (SPEC §11).
public struct SavedPullRequests: Codable, Equatable, Sendable {
    /// By local branch.
    public var byBranch: [String: PullRequest] = [:]
    public var baseRefs: [String: String] = [:]
    public var unpushed: [String: Int] = [:]
    public var read: Date?

    public init(
        byBranch: [String: PullRequest] = [:], baseRefs: [String: String] = [:],
        unpushed: [String: Int] = [:], read: Date? = nil
    ) {
        self.byBranch = byBranch
        self.baseRefs = baseRefs
        self.unpushed = unpushed
        self.read = read
    }
}

/// Where the reader is, in terms that survive a reload: a file and a line in it.
public struct ScrollAnchor: Codable, Equatable, Sendable {
    public var path: String
    /// New-side line number at the top of the view, or the old side for a deleted line.
    public var line: Int?
    public var isOldSide = false
    /// How far the top of the view sits below the top of the anchored row.
    public var offset: Double

    public init(path: String, line: Int?, isOldSide: Bool = false, offset: Double) {
        self.path = path
        self.line = line
        self.isOldSide = isOldSide
        self.offset = offset
    }
}
