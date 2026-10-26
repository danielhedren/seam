import SeamCore

/// A review thread as the diff shows it (SPEC §7.7): where its lines are now, and what its
/// summary row says.
public struct ThreadMarker: Equatable, Sendable {
    public var id: String
    public var side: ThreadAnchor.Side
    public var lines: ClosedRange<Int>
    public var latestAuthor: String
    /// The latest comment's first line.
    public var latest: String
    public var commentCount: Int
    public var isResolved: Bool
    public var source: ThreadSource
    /// A note asks no answer, so it's drawn in grey rather than the source's colour.
    public var isNote: Bool

    public init(
        id: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>, latestAuthor: String,
        latest: String, commentCount: Int, isResolved: Bool, source: ThreadSource = .seam,
        isNote: Bool = false
    ) {
        self.source = source
        self.isNote = isNote
        self.id = id
        self.side = side
        self.lines = lines
        self.latestAuthor = latestAuthor
        self.latest = latest
        self.commentCount = commentCount
        self.isResolved = isResolved
    }
}

/// A thread being written (SPEC §7.7): the diff opens its composer under the last line.
public struct DraftMarker: Equatable, Sendable {
    public var path: String
    public var side: ThreadAnchor.Side
    public var lines: ClosedRange<Int>

    public init(path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>) {
        self.path = path
        self.side = side
        self.lines = lines
    }
}

extension ThreadMarker {
    package var text: String { "\(summary)   \(tally)" }

    package var summary: String {
        source == .gitHub
            ? String(localized: "\(latestAuthor) on GitHub: \(latest)", bundle: .module)
            : "\(latestAuthor): \(latest)"
    }

    /// The count and status, which a summary too long for its column gives way to.
    package var tally: String {
        let count =
            commentCount == 1
            ? String(localized: "1 comment", bundle: .module)
            : String(localized: "\(commentCount) comments", bundle: .module)
        let status = isResolved ? String(localized: " · resolved", bundle: .module) : ""
        return "\(count)\(status)"
    }
}
