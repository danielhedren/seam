import Foundation
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

    public init(
        id: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>, latestAuthor: String,
        latest: String, commentCount: Int, isResolved: Bool
    ) {
        self.id = id
        self.side = side
        self.lines = lines
        self.latestAuthor = latestAuthor
        self.latest = latest
        self.commentCount = commentCount
        self.isResolved = isResolved
    }

    var text: String {
        let count =
            commentCount == 1
            ? String(localized: "1 comment", bundle: .module)
            : String(localized: "\(commentCount) comments", bundle: .module)
        let status = isResolved ? String(localized: " · resolved", bundle: .module) : ""
        return "\(latestAuthor): \(latest)   \(count)\(status)"
    }
}
