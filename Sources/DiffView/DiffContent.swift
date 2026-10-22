import Foundation
import GitKit
import SeamCore

public enum DiffLayoutMode: String, CaseIterable, Sendable {
    case unified
    case split
}

/// Everything the diff view shows. Equal content means nothing to redraw.
public struct DiffContent: Equatable, Sendable {
    public var review: ReviewDiff
    public var mode: DiffLayoutMode
    public var collapsed: Set<String>
    /// Full file contents, for context expansion; files without them get no gap rows.
    public var contents: [String: FileContents]
    public var expansions: [String: [Int: GapExpansion]]
    /// Syntax highlights per file; lines are drawn plain until theirs arrive (SPEC §8.4).
    public var syntax: [String: FileSyntax]
    public var wraps: Bool
    /// Viewed status per path, shown as each file header's checkbox (SPEC §7.4).
    public var viewed: [String: ViewedMarks.Status]
    public var tabWidth: Int
    /// Per-file widths from `.editorconfig`, over `tabWidth`.
    public var tabWidths: [String: Int]
    /// Review threads by path, placed on the lines they're on now (SPEC §7.7).
    public var threads: [String: [ThreadMarker]]

    public init(
        review: ReviewDiff, mode: DiffLayoutMode = .unified, collapsed: Set<String> = [],
        contents: [String: FileContents] = [:], expansions: [String: [Int: GapExpansion]] = [:],
        syntax: [String: FileSyntax] = [:], wraps: Bool = false,
        viewed: [String: ViewedMarks.Status] = [:], tabWidth: Int = 4,
        tabWidths: [String: Int] = [:], threads: [String: [ThreadMarker]] = [:]
    ) {
        self.threads = threads
        self.tabWidth = tabWidth
        self.tabWidths = tabWidths
        self.wraps = wraps
        self.viewed = viewed
        self.review = review
        self.mode = mode
        self.collapsed = collapsed
        self.contents = contents
        self.expansions = expansions
        self.syntax = syntax
    }

    public static let expandStep = 20

    static func lines(_ text: String) -> [Substring] { TextLines.split(text) }
}

/// How much of one gap between hunks the reader has revealed (SPEC §7.4). Gap 0 is above the
/// first hunk, gap `n` below hunk `n - 1`.
public struct GapExpansion: Equatable, Sendable {
    /// Lines shown below the hunk above the gap.
    public var top = 0
    /// Lines shown above the hunk below the gap.
    public var bottom = 0

    public init(top: Int = 0, bottom: Int = 0) {
        self.top = top
        self.bottom = bottom
    }

    public static let all = GapExpansion(top: Int.max / 2, bottom: 0)
}

public enum ExpandDirection: Equatable, Sendable {
    /// Reveal lines below the hunk above the gap.
    case down
    /// Reveal lines above the hunk below the gap.
    case up
    case all
}
