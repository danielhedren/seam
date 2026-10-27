import GitKit
import SeamCore

/// One side of a displayed line: what a gutter number and a text column show.
package struct SideLine: Equatable, Sendable {
    package var kind: DiffLine.Kind
    package var number: Int
    /// Tabs already expanded, so column arithmetic is plain character counting.
    package var text: String
    package var noNewlineAtEnd = false
    /// Word changes and syntax runs below are character ranges into `text`.
    package var highlights: [Range<Int>] = []
    package var syntax: [SyntaxSpan] = []
}

/// A unified-mode line, numbered on whichever sides it exists.
package struct UnifiedLine: Equatable, Sendable {
    package var old: Int?
    package var new: Int?
    package var kind: DiffLine.Kind
    package var text: String
    package var noNewline = false
    package var highlights: [Range<Int>] = []
    package var syntax: [SyntaxSpan] = []
}

/// The hidden part of a gap, with the controls that apply to it.
package struct GapRow: Equatable, Sendable {
    package var gap: Int
    var hidden: Int
    var canExpandDown: Bool
    var canExpandUp: Bool
}

/// A hunk header always keeps its row, so hunk navigation stops there, but it shows only when it
/// has a name or nothing else marks a jump in line numbers (SPEC §7.4).
package enum HunkHeaderStyle: Equatable, Sendable {
    case titled(String)
    case separator
    case hidden
}

package enum DiffRow: Equatable, Sendable {
    /// The file index of the cards above the first file, which belong to none.
    package static let preamble = -1

    case fileHeader(file: Int)
    case hunkHeader(file: Int, hunk: Int, HunkHeaderStyle)
    case line(file: Int, UnifiedLine)
    /// Split mode: a removed line paired with an added line, or context on both sides.
    case split(file: Int, left: SideLine?, right: SideLine?)
    /// Binary, mode-only, empty or deferred files, which have no lines to show.
    case notice(file: Int, text: String)
    case image(file: Int)
    /// Unchanged lines between hunks that aren't shown.
    case gap(file: Int, GapRow)
    /// A review thread's summary, after the last line it's on (SPEC §7.7).
    case thread(file: Int, ThreadMarker)
    /// The thread being read, open in place of its compact row.
    case openThread(file: Int, ThreadMarker)
    /// The composer for a new thread, after its last line and that line's threads.
    case draft(file: Int, DraftMarker)

    package var file: Int {
        switch self {
        case .fileHeader(let file), .hunkHeader(let file, _, _), .line(let file, _),
            .split(let file, _, _), .notice(let file, _), .gap(let file, _), .image(let file),
            .thread(let file, _), .openThread(let file, _), .draft(let file, _):
            file
        }
    }

    var isThread: Bool {
        switch self {
        case .thread, .openThread: true
        default: false
        }
    }

    package var isFileHeader: Bool {
        if case .fileHeader = self { true } else { false }
    }

    var isHunkHeader: Bool {
        if case .hunkHeader = self { true } else { false }
    }
}

package enum DiffSide: Hashable, Sendable {
    case unified
    case left
    case right
}
