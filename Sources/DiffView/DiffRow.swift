import GitKit
import SeamCore

/// One side of a displayed line: what a gutter number and a text column show.
struct SideLine: Equatable, Sendable {
    var kind: DiffLine.Kind
    var number: Int
    /// Tabs already expanded, so column arithmetic is plain character counting.
    var text: String
    var noNewlineAtEnd = false
    /// Word changes and syntax runs below are character ranges into `text`.
    var highlights: [Range<Int>] = []
    var syntax: [SyntaxSpan] = []
}

/// A unified-mode line, numbered on whichever sides it exists.
struct UnifiedLine: Equatable, Sendable {
    var old: Int?
    var new: Int?
    var kind: DiffLine.Kind
    var text: String
    var noNewline = false
    var highlights: [Range<Int>] = []
    var syntax: [SyntaxSpan] = []
}

/// The hidden part of a gap, with the controls that apply to it.
struct GapRow: Equatable, Sendable {
    var gap: Int
    var hidden: Int
    var canExpandDown: Bool
    var canExpandUp: Bool
}

enum DiffRow: Equatable, Sendable {
    case fileHeader(file: Int)
    case hunkHeader(file: Int, hunk: Int, text: String)
    case line(file: Int, UnifiedLine)
    /// Split mode: a removed line paired with an added line, or context on both sides.
    case split(file: Int, left: SideLine?, right: SideLine?)
    /// Binary, mode-only, empty or deferred files, which have no lines to show.
    case notice(file: Int, text: String)
    case image(file: Int)
    /// Unchanged lines between hunks that aren't shown.
    case gap(file: Int, GapRow)

    var file: Int {
        switch self {
        case .fileHeader(let file), .hunkHeader(let file, _, _), .line(let file, _),
            .split(let file, _, _), .notice(let file, _), .gap(let file, _), .image(let file):
            file
        }
    }

    var isFileHeader: Bool {
        if case .fileHeader = self { true } else { false }
    }

    var isHunkHeader: Bool {
        if case .hunkHeader = self { true } else { false }
    }
}

enum DiffSide: Hashable, Sendable {
    case unified
    case left
    case right
}
