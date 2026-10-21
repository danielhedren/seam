import GitKit
import SeamCore

public enum DiffLayoutMode: String, CaseIterable, Sendable {
    case unified
    case split
}

/// One side of a displayed line: what a gutter number and a text column show.
struct SideLine: Equatable, Sendable {
    var kind: DiffLine.Kind
    var number: Int
    /// Tabs already expanded, so column arithmetic is plain character counting.
    var text: String
    var noNewlineAtEnd = false
    /// Word-level changes, as character ranges into `text`.
    var highlights: [Range<Int>] = []
}

/// A unified-mode line, numbered on whichever sides it exists.
struct UnifiedLine: Equatable, Sendable {
    var old: Int?
    var new: Int?
    var kind: DiffLine.Kind
    var text: String
    var noNewline = false
    var highlights: [Range<Int>] = []
}

/// Everything the diff view shows. Equal content means nothing to redraw.
public struct DiffContent: Equatable, Sendable {
    public var review: ReviewDiff
    public var mode: DiffLayoutMode
    public var collapsed: Set<String>
    /// Full file contents, for context expansion; files without them get no gap rows.
    public var contents: [String: FileContents]
    public var expansions: [String: [Int: GapExpansion]]

    public init(
        review: ReviewDiff, mode: DiffLayoutMode = .unified, collapsed: Set<String> = [],
        contents: [String: FileContents] = [:], expansions: [String: [Int: GapExpansion]] = [:]
    ) {
        self.review = review
        self.mode = mode
        self.collapsed = collapsed
        self.contents = contents
        self.expansions = expansions
    }

    /// Lines revealed per click on a gap's arrow.
    public static let expandStep = 20

    /// Each file's new side split into lines, without the empty piece after a final newline.
    var newLines: [String: [Substring]] {
        contents.compactMapValues { contents in
            guard let text = contents.new else { return nil }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if text.hasSuffix("\n") { lines.removeLast() }
            return lines
        }
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
    /// Unchanged lines between hunks that aren't shown.
    case gap(file: Int, GapRow)

    var file: Int {
        switch self {
        case .fileHeader(let file), .hunkHeader(let file, _, _), .line(let file, _),
            .split(let file, _, _), .notice(let file, _), .gap(let file, _):
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
    /// The single text column of unified mode.
    case unified
    case left
    case right
}

enum DiffRowBuilder {
    /// `newLines` holds each file's new side split into lines, where it was loaded; files
    /// without it get no gap rows.
    static func rows(
        for review: ReviewDiff, mode: DiffLayoutMode, collapsed: Set<String> = [],
        newLines: [String: [Substring]] = [:], expansions: [String: [Int: GapExpansion]] = [:],
        tabWidth: Int = 4
    ) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(review.files.reduce(0) { $0 + $1.diff.hunks.count * 8 + 1 })
        for (index, file) in review.files.enumerated() {
            rows.append(.fileHeader(file: index))
            guard !collapsed.contains(file.diff.path) else { continue }
            if let notice = notice(for: file) {
                rows.append(.notice(file: index, text: notice))
                continue
            }
            let lines = file.diff.newPath == nil ? nil : newLines[file.diff.path]
            let fileExpansions = expansions[file.diff.path] ?? [:]
            var next = (old: 1, new: 1)
            func gap(_ number: Int, until end: Int) {
                guard let lines else { return }
                rows += gapRows(
                    file: index, gap: number, newRange: next.new..<end,
                    oldOffset: next.old - next.new, lines: lines,
                    expansion: fileExpansions[number] ?? GapExpansion(), mode: mode,
                    tabWidth: tabWidth, isFirst: number == 0,
                    isLast: number == file.diff.hunks.count)
            }
            for (hunkIndex, hunk) in file.diff.hunks.enumerated() {
                let first = Self.first(hunk)
                gap(hunkIndex, until: first.new)
                next = Self.next(hunk)
                rows.append(.hunkHeader(file: index, hunk: hunkIndex, text: header(hunk)))
                let texts = hunk.lines.map { expandTabs($0.text, width: tabWidth) }
                let highlights = wordHighlights(hunk.lines, texts)
                switch mode {
                case .unified:
                    for (offset, line) in hunk.lines.enumerated() {
                        rows.append(
                            .line(
                                file: index,
                                UnifiedLine(
                                    old: line.oldNumber, new: line.newNumber, kind: line.kind,
                                    text: texts[offset], noNewline: line.noNewlineAtEnd,
                                    highlights: highlights[offset])))
                    }
                case .split:
                    rows += splitRows(hunk.lines, texts, highlights, file: index)
                }
            }
            if let lines, !file.diff.hunks.isEmpty {
                gap(file.diff.hunks.count, until: lines.count + 1)
            }
        }
        return rows
    }

    /// A hunk's first line on each side. A side with no lines names the line before it.
    static func first(_ hunk: Hunk) -> (old: Int, new: Int) {
        (
            hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart,
            hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
        )
    }

    /// The first line after a hunk on each side.
    static func next(_ hunk: Hunk) -> (old: Int, new: Int) {
        (
            hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart + hunk.oldCount,
            hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart + hunk.newCount
        )
    }

    /// Revealed context at the top and bottom of a gap, with the hidden rest as one gap row.
    static func gapRows(
        file: Int, gap: Int, newRange: Range<Int>, oldOffset: Int, lines: [Substring],
        expansion: GapExpansion, mode: DiffLayoutMode, tabWidth: Int, isFirst: Bool,
        isLast: Bool
    ) -> [DiffRow] {
        let range = newRange.clamped(to: 1..<(lines.count + 1))
        guard !range.isEmpty else { return [] }
        let top = isFirst ? 0 : min(expansion.top, range.count)
        let bottom = isLast ? 0 : min(expansion.bottom, range.count - top)
        let all = expansion.top >= range.count
        func context(_ numbers: Range<Int>) -> [DiffRow] {
            numbers.map { number in
                let text = expandTabs(String(lines[number - 1]), width: tabWidth)
                let old = number + oldOffset
                return switch mode {
                case .unified:
                    .line(
                        file: file, UnifiedLine(old: old, new: number, kind: .context, text: text))
                case .split:
                    .split(
                        file: file, left: SideLine(kind: .context, number: old, text: text),
                        right: SideLine(kind: .context, number: number, text: text))
                }
            }
        }
        if all { return context(range) }
        var rows = context(range.lowerBound..<(range.lowerBound + top))
        let hidden = range.count - top - bottom
        if hidden > 0 {
            rows.append(
                .gap(
                    file: file,
                    GapRow(gap: gap, hidden: hidden, canExpandDown: !isFirst, canExpandUp: !isLast))
            )
        }
        rows += context((range.upperBound - bottom)..<range.upperBound)
        return rows
    }

    /// The gap row's text and the character ranges of its controls.
    static func gapLabel(_ gap: GapRow) -> (text: String, controls: [(Range<Int>, ExpandDirection)])
    {
        var text = ""
        var controls: [(Range<Int>, ExpandDirection)] = []
        func add(_ label: String, _ direction: ExpandDirection) {
            let start = text.count
            text += label
            controls.append((start..<text.count, direction))
            text += "    "
        }
        let step = min(DiffContent.expandStep, gap.hidden)
        if gap.canExpandDown { add("↓ \(step)", .down) }
        if gap.canExpandUp { add("↑ \(step)", .up) }
        add(String(localized: "Show all \(gap.hidden) lines", bundle: .module), .all)
        return (text, controls)
    }

    static func header(_ hunk: Hunk) -> String {
        let section = hunk.section.isEmpty ? "" : " \(hunk.section)"
        return "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            + section
    }

    static func notice(for file: ReviewFile) -> String? {
        if file.isDeferred { return String(localized: "Large file not loaded", bundle: .module) }
        if file.diff.isBinary { return String(localized: "Binary file", bundle: .module) }
        guard file.diff.hunks.isEmpty else { return nil }
        if let old = file.diff.oldMode, let new = file.diff.newMode, old != new,
            file.diff.status == .modified
        {
            return String(localized: "Mode changed from \(old) to \(new)", bundle: .module)
        }
        switch file.diff.status {
        case .renamed: return String(localized: "Renamed without changes", bundle: .module)
        case .copied: return String(localized: "Copied without changes", bundle: .module)
        case .added: return String(localized: "Empty file", bundle: .module)
        case .deleted: return String(localized: "Empty file deleted", bundle: .module)
        case .modified: return String(localized: "No content changes", bundle: .module)
        }
    }

    /// Word highlights per hunk line: each run of removed lines and the added lines after it form
    /// one change block for `IntraLineDiff`.
    static func wordHighlights(_ lines: [DiffLine], _ texts: [String]) -> [[Range<Int>]] {
        var result = [[Range<Int>]](repeating: [], count: lines.count)
        var index = 0
        while index < lines.count {
            guard lines[index].kind != .context else {
                index += 1
                continue
            }
            var removed: [Int] = []
            var added: [Int] = []
            while index < lines.count, lines[index].kind == .removed {
                removed.append(index)
                index += 1
            }
            while index < lines.count, lines[index].kind == .added {
                added.append(index)
                index += 1
            }
            let block = IntraLineDiff.highlights(
                removed: removed.map { texts[$0] }, added: added.map { texts[$0] })
            for (offset, line) in removed.enumerated() { result[line] = block.removed[offset] }
            for (offset, line) in added.enumerated() { result[line] = block.added[offset] }
        }
        return result
    }

    /// Runs of removed lines pair with the added lines that follow them, in order.
    static func splitRows(
        _ lines: [DiffLine], _ texts: [String], _ highlights: [[Range<Int>]], file: Int
    ) -> [DiffRow] {
        var rows: [DiffRow] = []
        var removed: [SideLine] = []
        var added: [SideLine] = []

        func flush() {
            for offset in 0..<max(removed.count, added.count) {
                rows.append(
                    .split(
                        file: file, left: offset < removed.count ? removed[offset] : nil,
                        right: offset < added.count ? added[offset] : nil))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for (offset, line) in lines.enumerated() {
            let text = texts[offset]
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(
                    SideLine(
                        kind: .removed, number: line.oldNumber ?? 0, text: text,
                        noNewlineAtEnd: line.noNewlineAtEnd, highlights: highlights[offset]))
            case .added:
                added.append(
                    SideLine(
                        kind: .added, number: line.newNumber ?? 0, text: text,
                        noNewlineAtEnd: line.noNewlineAtEnd, highlights: highlights[offset]))
            case .context:
                flush()
                rows.append(
                    .split(
                        file: file,
                        left: SideLine(
                            kind: .context, number: line.oldNumber ?? 0, text: text,
                            noNewlineAtEnd: line.noNewlineAtEnd),
                        right: SideLine(
                            kind: .context, number: line.newNumber ?? 0, text: text,
                            noNewlineAtEnd: line.noNewlineAtEnd)))
            }
        }
        flush()
        return rows
    }

    static func expandTabs(_ text: String, width: Int) -> String {
        guard text.contains("\t") || text.hasSuffix("\r") else { return text }
        var result = ""
        var column = 0
        for character in text {
            switch character {
            case "\t":
                let spaces = width - column % width
                result += String(repeating: " ", count: spaces)
                column += spaces
            // CRLF files: the CR is drawn as a visible marker rather than moving the caret.
            case "\r":
                result += "␍"
                column += 1
            default:
                result.append(character)
                column += 1
            }
        }
        return result
    }
}
