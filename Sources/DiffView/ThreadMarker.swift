import AppKit
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

    var text: String { "\(summary)   \(tally)" }

    var summary: String {
        source == .gitHub
            ? String(localized: "\(latestAuthor) on GitHub: \(latest)", bundle: .module)
            : "\(latestAuthor): \(latest)"
    }

    /// The count and status, which a summary too long for its column gives way to.
    var tally: String {
        let count =
            commentCount == 1
            ? String(localized: "1 comment", bundle: .module)
            : String(localized: "\(commentCount) comments", bundle: .module)
        let status = isResolved ? String(localized: " · resolved", bundle: .module) : ""
        return "\(count)\(status)"
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

/// Review threads' colour wherever they show: posted, being written, and the lines `c` would
/// comment on (SPEC §7.7); GitHub's threads in its blue (§7.9).
public enum ThreadColor {
    public static let accent = NSColor.systemYellow
    /// Behind a thread's row and the composer, light enough for text on either appearance.
    public static let wash = accent.withAlphaComponent(washAlpha)
    static let washAlpha = 0.14
    /// Primer's accent, as github.com draws links and its own highlights.
    public static let gitHubAccent = primerBlue(alpha: 1)
    public static let gitHubWash = primerBlue(alpha: washAlpha)

    private static func primerBlue(alpha: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x44 / 255, green: 0x93 / 255, blue: 0xF8 / 255, alpha: alpha)
                : NSColor(srgbRed: 0x09 / 255, green: 0x69 / 255, blue: 0xDA / 255, alpha: alpha)
        }
    }

    /// A note's grey, for something to know that asks no answer.
    public static let noteAccent = NSColor.systemGray
    public static let noteWash = noteAccent.withAlphaComponent(washAlpha)

    public static func accent(_ source: ThreadSource, note: Bool = false) -> NSColor {
        note ? noteAccent : source == .gitHub ? gitHubAccent : accent
    }

    public static func wash(_ source: ThreadSource, note: Bool = false) -> NSColor {
        note ? noteWash : source == .gitHub ? gitHubWash : wash
    }
}
