import Foundation

/// `seam threads` output, written for an agent to read (SPEC §13).
public enum ThreadText {
    /// `showsWorktree` names the thread's worktree, for listings that span the repo. `read` is
    /// when a pull request thread was read from GitHub, and `placement` where its lines are in
    /// the worktree now. Times are ISO 8601, as `--since` takes them.
    public static func format(
        _ thread: ReviewThread, showsWorktree: Bool = false, read: Date? = nil,
        placement: ThreadPlacement? = nil, timeZone: TimeZone = .current
    ) -> String {
        let anchor = thread.anchor
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let lines =
            anchor.lines.count == 1
            ? "\(anchor.lines.lowerBound)"
            : "\(anchor.lines.lowerBound)-\(anchor.lines.upperBound)"
        let place =
            thread.github?.onFile == true
            ? "\(anchor.path) (whole file)" : "\(anchor.path):\(lines)"
        let side = anchor.side == .old ? " (old side)" : ""
        let source = thread.github.map { " on GitHub pull request #\($0.pullRequest)" } ?? ""
        var text = [
            "#\(thread.id)  \(thread.isResolved ? "resolved" : "open")  "
                + "\(place)\(side)  opened by \(thread.author)\(source)"
                + (showsWorktree ? "  in \(thread.worktree)" : "")
        ]
        if let note = note(anchor, placement) { text.append(note) }
        if let github = thread.github, let reply = thread.gitHubReply {
            let when = read.map { " at \(formatter.string(from: $0))" } ?? ""
            text += [
                "  Read from \(github.repo.slug)\(when). Seam can't answer it; write your reply to reply.md, then run:",
                "    \(reply)",
                "  GitHub thread \(github.threadID) · \(github.url)",
            ]
        }
        let width = String(anchor.lines.upperBound).count
        for (offset, line) in anchor.text.enumerated() {
            let number = String(anchor.lines.lowerBound + offset)
            text.append(
                "    " + String(repeating: " ", count: width - number.count) + number + " │ "
                    + line)
        }
        for comment in thread.comments {
            let id = comment.githubID.map { " · GitHub comment \($0)" } ?? ""
            text.append("  \(comment.author) · \(formatter.string(from: comment.date))\(id)")
            text += comment.body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }
        }
        return text.joined(separator: "\n")
    }

    /// What the line numbers mean now: the comment's are from when it was written.
    private static func note(_ anchor: ThreadAnchor, _ placement: ThreadPlacement?) -> String? {
        if anchor.side == .old {
            return "  Old side: lines from the base that the change removed."
        }
        switch placement {
        case .lines(let now) where now != anchor.lines:
            let lines =
                now.count == 1 ? "\(now.lowerBound)" : "\(now.lowerBound)-\(now.upperBound)"
            return "  Now at \(anchor.path):\(lines): the lines moved since."
        case .outdated:
            return
                "  Outdated: these lines aren't in \(anchor.path) any more, so it may be addressed."
        case .notShown:
            return "  \(anchor.path) isn't in this worktree any more."
        case .lines, .later, nil: return nil
        }
    }

    /// `src/a.cs:12` or `src/a.cs:12-14`; nil when it isn't one of those.
    public static func location(_ argument: String) -> (path: String, lines: ClosedRange<Int>)? {
        guard let colon = argument.lastIndex(of: ":") else { return nil }
        let path = String(argument[..<colon])
        let range = argument[argument.index(after: colon)...].split(
            separator: "-", omittingEmptySubsequences: false)
        guard !path.isEmpty, (1...2).contains(range.count),
            let first = Int(range[0]), let last = Int(range.last ?? ""), first >= 1,
            first <= last
        else { return nil }
        return (path, first...last)
    }
}

/// A thread as `seam --json` prints it (SPEC §13): the stored thread's own fields, plus what an
/// agent would otherwise work out itself.
public struct ThreadOutput: Encodable, Sendable {
    public var thread: ReviewThread
    /// When a pull request thread was read from GitHub.
    public var readAt: Date?
    public var placement: ThreadPlacement?

    public init(_ thread: ReviewThread, readAt: Date? = nil, placement: ThreadPlacement? = nil) {
        self.thread = thread
        self.readAt = readAt
        self.placement = placement
    }

    private enum Keys: String, CodingKey {
        case source, replyCommand, readAt, placement
    }

    public func encode(to encoder: any Encoder) throws {
        try thread.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(thread.source == .gitHub ? "github" : "seam", forKey: .source)
        try container.encodeIfPresent(thread.gitHubReply, forKey: .replyCommand)
        try container.encodeIfPresent(readAt, forKey: .readAt)
        try container.encodeIfPresent(placement, forKey: .placement)
    }
}

extension ThreadPlacement: Encodable {
    private enum Keys: String, CodingKey {
        case state, lines
    }

    /// `{"state": "lines", "lines": [30, 31]}`: where the lines are now, first and last.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .lines(let lines):
            try container.encode("lines", forKey: .state)
            try container.encode([lines.lowerBound, lines.upperBound], forKey: .lines)
        case .outdated: try container.encode("outdated", forKey: .state)
        case .later: try container.encode("later", forKey: .state)
        case .notShown: try container.encode("fileGone", forKey: .state)
        }
    }
}
