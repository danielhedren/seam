import Foundation
import GitKit

/// Where a thread read from a pull request came from (SPEC §7.9): enough for an agent to answer
/// it on GitHub with its own `gh`.
public struct GitHubThreadSource: Codable, Equatable, Sendable {
    public var repo: GitHubRepo
    public var pullRequest: Int
    /// GitHub's node id, which GraphQL's thread mutations take.
    public var threadID: String
    public var url: String
    /// On the whole file rather than lines.
    public var onFile: Bool

    public init(
        repo: GitHubRepo, pullRequest: Int, threadID: String, url: String, onFile: Bool = false
    ) {
        self.repo = repo
        self.pullRequest = pullRequest
        self.threadID = threadID
        self.url = url
        self.onFile = onFile
    }
}

extension ReviewThread {
    public static let gitHubPrefix = "gh-"

    /// The command that answers this thread on GitHub; nil for Seam's own threads.
    public var gitHubReply: String? {
        guard let github, let first = comments.first?.githubID else { return nil }
        return "gh api --hostname \(github.repo.host) -X POST repos/\(github.repo.owner)/"
            + "\(github.repo.name)/pulls/\(github.pullRequest)/comments/\(first)/replies "
            + "-f body='…'"
    }
}

/// A pull request's review threads as Seam threads (SPEC §7.9).
public enum GitHubThreads {
    public static func threads(
        from threads: [GitHubReviewThread], worktree: String, repo: GitHubRepo, pullRequest: Int
    ) -> [ReviewThread] {
        threads.compactMap { thread in
            guard let first = thread.comments.first else { return nil }
            let side: ThreadAnchor.Side = thread.side == .left ? .old : .new
            let anchor: ThreadAnchor
            if let lines = thread.lines {
                let text = Self.lines(lines, side: side, in: first.diffHunk)
                anchor = ThreadAnchor(path: thread.path, side: side, lines: lines, text: text ?? [])
            } else {
                anchor = ThreadAnchor(path: thread.path, side: side, lines: 1...1, text: [])
            }
            return ReviewThread(
                id: "\(ReviewThread.gitHubPrefix)\(first.id)", worktree: worktree, anchor: anchor,
                author: first.author, isResolved: thread.isResolved,
                comments: thread.comments.map {
                    ThreadComment(
                        id: String($0.id), author: $0.author, body: $0.body, date: $0.created,
                        githubID: $0.id)
                },
                updated: thread.comments.map(\.created).max(),
                github: GitHubThreadSource(
                    repo: repo, pullRequest: pullRequest, threadID: thread.id, url: first.url,
                    onFile: thread.lines == nil))
        }
    }

    /// The text of `lines` on `side` of a unified diff hunk; nil unless the hunk has them all.
    static func lines(_ lines: ClosedRange<Int>, side: ThreadAnchor.Side, in hunk: String)
        -> [String]?
    {
        var old = 0
        var new = 0
        var found: [Int: String] = [:]
        for line in hunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") {
                guard let start = hunkStart(line) else { return nil }
                (old, new) = start
                continue
            }
            let text = String(line.dropFirst())
            switch line.first {
            case " ":
                if side == .old { found[old] = text } else { found[new] = text }
                old += 1
                new += 1
            case "-":
                if side == .old { found[old] = text }
                old += 1
            case "+":
                if side == .new { found[new] = text }
                new += 1
            default: continue
            }
        }
        let text = lines.compactMap { found[$0] }
        return text.count == lines.count ? text : nil
    }

    /// `@@ -12,3 +14,4 @@` → (12, 14).
    private static func hunkStart(_ header: Substring) -> (Int, Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
            let old = Int(parts[1].dropFirst().prefix { $0 != "," }),
            let new = Int(parts[2].dropFirst().prefix { $0 != "," })
        else { return nil }
        return (old, new)
    }

    /// A newly read set, keeping the previous `updated` of every thread that hasn't changed and
    /// stamping `now` on those that have (a thread resolved on GitHub gets no new comment), so
    /// `seam wait --since` sees each change once.
    public static func stamped(_ threads: [ReviewThread], previous: [ReviewThread], now: Date)
        -> [ReviewThread]
    {
        let before = Dictionary(
            previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return threads.map { thread in
            var thread = thread
            guard let old = before[thread.id] else { return thread }
            thread.updated = old.updated
            if thread != old { thread.updated = now }
            return thread
        }
    }
}
