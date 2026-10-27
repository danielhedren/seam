import Foundation

/// Where a thread is in the diff as it is now (SPEC §7.7).
public enum ThreadPlacement: Equatable, Sendable {
    case lines(ClosedRange<Int>)
    /// Its lines are gone from the file.
    case outdated
    /// Written on a commit after the newest one shown, so its lines may not exist yet.
    case later
    /// Its file isn't in this diff, its text isn't loaded, or it has no lines to look for.
    case notShown
}

public struct PlacedThread: Equatable, Identifiable, Sendable {
    public var thread: ReviewThread
    public var placement: ThreadPlacement
    /// The file it's on in this diff: its anchor's, or where a rename took that.
    public var path: String

    public init(thread: ReviewThread, placement: ThreadPlacement, path: String? = nil) {
        self.thread = thread
        self.placement = placement
        self.path = path ?? thread.anchor.path
    }

    public var id: String { thread.id }

    /// The diff shows it on its lines, rather than under its file's header or above the files.
    public var isInDiff: Bool { if case .lines = placement { true } else { false } }
}

/// Places threads against the files a diff shows, as pure functions, so the app and `seam`
/// agree on where a thread is (SPEC §7.7, §7.9).
public enum ThreadPlacer {
    public struct Context {
        /// The paths the diff shows.
        public var paths: Set<String>
        /// A file's lines on one side; nil when they aren't loaded.
        public var text: (_ path: String, _ side: ThreadAnchor.Side) -> [Substring]?
        /// The branch's commits, newest first, and the newest one picked in the commit list;
        /// nil when a scope is shown.
        public var commits: [String]
        public var newestShown: String?
        /// Renamed files' new paths by their old: a pull request's comment keeps the old one.
        public var renamed: [String: String]

        public init(
            paths: Set<String>,
            text: @escaping (_ path: String, _ side: ThreadAnchor.Side) -> [Substring]?,
            commits: [String] = [], newestShown: String? = nil, renamed: [String: String] = [:]
        ) {
            self.paths = paths
            self.text = text
            self.commits = commits
            self.newestShown = newestShown
            self.renamed = renamed
        }
    }

    /// Every thread with where it is now, open ones first, then by file and line.
    public static func place(_ threads: [ReviewThread], in context: Context) -> [PlacedThread] {
        threads.map { thread in
            let path = path(of: thread, in: context)
            return PlacedThread(
                thread: thread, placement: placement(of: thread, at: path, in: context), path: path)
        }
        .sorted { lhs, rhs in
            if lhs.thread.isResolved != rhs.thread.isResolved { return !lhs.thread.isResolved }
            if lhs.path != rhs.path {
                return ReviewDiffBuilder.precedesInTree(lhs.path, rhs.path)
            }
            return lhs.thread.anchor.lines.lowerBound < rhs.thread.anchor.lines.lowerBound
        }
    }

    private static func path(of thread: ReviewThread, in context: Context) -> String {
        let path = thread.anchor.path
        guard !context.paths.contains(path), let renamed = context.renamed[path] else {
            return path
        }
        return renamed
    }

    static func placement(of thread: ReviewThread, at path: String, in context: Context)
        -> ThreadPlacement
    {
        let anchor = thread.anchor
        guard context.paths.contains(path), thread.github?.onFile != true,
            let text = context.text(path, anchor.side)
        else { return .notShown }
        if let lines = anchor.locate(in: text) { return .lines(lines) }
        // A pull request comment whose hunk didn't show its lines was never placeable.
        if thread.source == .gitHub, anchor.text.isEmpty { return .notShown }
        return isAfterShownCommits(thread, context) ? .later : .outdated
    }

    private static func isAfterShownCommits(_ thread: ReviewThread, _ context: Context) -> Bool {
        guard let commit = thread.github?.commit, let newest = context.newestShown,
            let written = context.commits.firstIndex(of: commit),
            let shown = context.commits.firstIndex(of: newest)
        else { return false }
        return written < shown
    }
}
