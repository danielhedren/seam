import GitKit
import SeamCore

public enum DiffLayoutMode: String, CaseIterable, Sendable {
    case unified
    case split
}

/// One side of a displayed line: what a gutter number and a text column show.
public struct SideLine: Equatable, Sendable {
    public var kind: DiffLine.Kind
    public var number: Int
    /// Tabs already expanded, so column arithmetic is plain character counting.
    public var text: String
    public var noNewlineAtEnd = false
}

public enum DiffRow: Equatable, Sendable {
    case fileHeader(file: Int)
    case hunkHeader(file: Int, hunk: Int, text: String)
    /// Unified mode: one line, numbered on whichever sides it exists.
    case line(file: Int, old: Int?, new: Int?, kind: DiffLine.Kind, text: String, noNewline: Bool)
    /// Split mode: a removed line paired with an added line, or context on both sides.
    case split(file: Int, left: SideLine?, right: SideLine?)
    /// Binary, mode-only, empty or deferred files, which have no lines to show.
    case notice(file: Int, text: String)

    public var file: Int {
        switch self {
        case .fileHeader(let file), .hunkHeader(let file, _, _), .line(let file, _, _, _, _, _),
            .split(let file, _, _), .notice(let file, _):
            file
        }
    }

    public var isFileHeader: Bool {
        if case .fileHeader = self { true } else { false }
    }

    public var isHunkHeader: Bool {
        if case .hunkHeader = self { true } else { false }
    }
}

public enum DiffSide: Hashable, Sendable {
    /// The single text column of unified mode.
    case unified
    case left
    case right
}

public enum DiffRowBuilder {
    public static func rows(
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
                switch mode {
                case .unified:
                    for line in hunk.lines {
                        rows.append(
                            .line(
                                file: index, old: line.oldNumber, new: line.newNumber,
                                kind: line.kind, text: expandTabs(line.text, width: tabWidth),
                                noNewline: line.noNewlineAtEnd))
                    }
                case .split:
                    rows += splitRows(hunk.lines, file: index, tabWidth: tabWidth)
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
        if file.isDeferred { return "Large file not loaded" }
        if file.diff.isBinary { return "Binary file" }
        guard file.diff.hunks.isEmpty else { return nil }
        if let old = file.diff.oldMode, let new = file.diff.newMode, old != new,
            file.diff.status == .modified
        {
            return "Mode changed from \(old) to \(new)"
        }
        switch file.diff.status {
        case .renamed: return "Renamed without changes"
        case .copied: return "Copied without changes"
        case .added: return "Empty file"
        case .deleted: return "Empty file deleted"
        case .modified: return "No content changes"
        }
    }

    /// Runs of removed lines pair with the added lines that follow them, in order.
    static func splitRows(_ lines: [DiffLine], file: Int, tabWidth: Int) -> [DiffRow] {
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

        for line in lines {
            let text = expandTabs(line.text, width: tabWidth)
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(
                    SideLine(
                        kind: .removed, number: line.oldNumber ?? 0, text: text,
                        noNewlineAtEnd: line.noNewlineAtEnd))
            case .added:
                added.append(
                    SideLine(
                        kind: .added, number: line.newNumber ?? 0, text: text,
                        noNewlineAtEnd: line.noNewlineAtEnd))
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
