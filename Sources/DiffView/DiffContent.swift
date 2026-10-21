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
    /// Long lines wrap at the view's width instead of scrolling sideways (SPEC §7.4, `w`).
    public var wraps: Bool

    public init(
        review: ReviewDiff, mode: DiffLayoutMode = .unified, collapsed: Set<String> = [],
        contents: [String: FileContents] = [:], expansions: [String: [Int: GapExpansion]] = [:],
        syntax: [String: FileSyntax] = [:], wraps: Bool = false
    ) {
        self.wraps = wraps
        self.review = review
        self.mode = mode
        self.collapsed = collapsed
        self.contents = contents
        self.expansions = expansions
        self.syntax = syntax
    }

    /// Lines revealed per click on a gap's arrow.
    public static let expandStep = 20

    /// A file's text split into lines, without the empty piece after a final newline. Splits on
    /// the byte: `"\r\n"` is one Character, so a Character split would see a CRLF file as one
    /// line. Each line keeps its `\r`, like the patch's lines do.
    static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { Substring($0) }
        if text.utf8.last == UInt8(ascii: "\n") { lines.removeLast() }
        return lines
    }
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
