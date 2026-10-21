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

enum DiffRow: Equatable, Sendable {
    case fileHeader(file: Int)
    case hunkHeader(file: Int, hunk: Int, text: String)
    case line(file: Int, UnifiedLine)
    /// Split mode: a removed line paired with an added line, or context on both sides.
    case split(file: Int, left: SideLine?, right: SideLine?)
    /// Binary, mode-only, empty or deferred files, which have no lines to show.
    case notice(file: Int, text: String)

    var file: Int {
        switch self {
        case .fileHeader(let file), .hunkHeader(let file, _, _), .line(let file, _),
            .split(let file, _, _), .notice(let file, _):
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
    static func rows(
        for review: ReviewDiff, mode: DiffLayoutMode, collapsed: Set<String> = [],
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
            for (hunkIndex, hunk) in file.diff.hunks.enumerated() {
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
        }
        return rows
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
