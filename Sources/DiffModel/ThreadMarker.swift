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
    /// The card's title, which the collapsed card shows too.
    public var title: String
    public var spot: Spot

    public init(
        id: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>, latestAuthor: String,
        latest: String, commentCount: Int, isResolved: Bool, source: ThreadSource = .seam,
        isNote: Bool = false, title: String = "", spot: Spot = .lines
    ) {
        self.title = title
        self.spot = spot
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

extension ThreadMarker {
    /// Where its card goes (SPEC §7.7).
    public enum Spot: Equatable, Sendable {
        /// On its lines: a gutter mark on them and the card after the last.
        case lines
        /// Its lines are gone: the card goes after `lines.upperBound`, which is where they'd be
        /// now, without a mark.
        case near
        /// On the whole file: under the file's header.
        case file
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
