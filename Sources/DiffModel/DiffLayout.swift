import Foundation
import GitKit
import SeamCore

/// Row positions as prefix sums of row heights (SPEC §8.5). Pure, so hit testing, navigation and
/// scroll anchoring are unit tested without a window.
package struct DiffLayout: Equatable, Sendable {
    package struct Metrics: Equatable, Sendable {
        package var lineHeight: Double
        package var fileHeaderHeight: Double
        package var characterWidth: Double
        var imageHeight = 240.0
        /// Taller than a line, so a thread's row stands apart from the code around it.
        package var threadRowHeight: Double { (lineHeight * 1.6).rounded() }

        package init(lineHeight: Double, fileHeaderHeight: Double, characterWidth: Double) {
            self.lineHeight = lineHeight
            self.fileHeaderHeight = fileHeaderHeight
            self.characterWidth = characterWidth
        }
    }

    package let rows: [DiffRow]
    package let metrics: Metrics
    /// `offsets[i]` is the top of row `i`; the last element is the total height.
    private let offsets: [Double]
    /// The longest text in characters, for the document width.
    let maxColumns: Int
    /// Characters per visual line when wrapping; nil when lines don't wrap.
    package let wrapColumns: Int?

    /// The card's row (a draft or the open thread) is as tall as its view says.
    package let cardHeight: Double

    package init(rows: [DiffRow], metrics: Metrics, wrapColumns: Int? = nil, cardHeight: Double = 0)
    {
        self.rows = rows
        self.metrics = metrics
        self.wrapColumns = wrapColumns
        self.cardHeight = cardHeight
        var offsets = [Double]()
        offsets.reserveCapacity(rows.count + 1)
        var y = 0.0
        var columns = 0
        for row in rows {
            offsets.append(y)
            let height =
                switch row {
                case .fileHeader: metrics.fileHeaderHeight
                case .image: metrics.imageHeight
                case .draft, .openThread: cardHeight
                case .hunkHeader(_, _, .separator): (metrics.lineHeight / 3).rounded()
                case .hunkHeader(_, _, .hidden): 0.0
                case .thread: metrics.threadRowHeight
                case .line(_, let line):
                    metrics.lineHeight * Double(Self.visualLines(line.text.count, wrapColumns))
                case .split(_, let left, let right):
                    metrics.lineHeight
                        * Double(
                            max(
                                Self.visualLines(left?.text.count ?? 0, wrapColumns),
                                Self.visualLines(right?.text.count ?? 0, wrapColumns)))
                default: metrics.lineHeight
                }
            y += height
            columns = max(columns, Self.columns(row))
        }
        offsets.append(y)
        self.offsets = offsets
        maxColumns = columns
    }

    package var totalHeight: Double { offsets.last ?? 0 }

    /// Monospaced text wraps at a fixed column, so a row's height follows from its length.
    static func visualLines(_ count: Int, _ wrapColumns: Int?) -> Int {
        guard let wrapColumns, wrapColumns > 0, count > wrapColumns else { return 1 }
        return (count + wrapColumns - 1) / wrapColumns
    }

    /// `range` cut at each wrap point: the visual line of each piece and its columns within it.
    package static func segments(_ range: Range<Int>, wrapColumns: Int?) -> [(
        line: Int, columns: Range<Int>
    )] {
        guard let wrapColumns, wrapColumns > 0 else { return [(0, range)] }
        var segments: [(line: Int, columns: Range<Int>)] = []
        var start = range.lowerBound
        repeat {
            let line = start / wrapColumns
            let end = min(range.upperBound, (line + 1) * wrapColumns)
            segments.append((line, (start - line * wrapColumns)..<(end - line * wrapColumns)))
            start = end
        } while start < range.upperBound
        return segments
    }

    static func maxColumns(_ rows: [DiffRow]) -> Int {
        rows.reduce(0) { max($0, columns($1)) }
    }

    package func top(of row: Int) -> Double { offsets[min(max(row, 0), rows.count)] }

    package func height(of row: Int) -> Double { top(of: row + 1) - top(of: row) }

    /// The row containing `y`, clamped to the rows that exist; nil when there are none.
    package func row(at y: Double) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    package func rows(in minY: Double, _ maxY: Double) -> Range<Int> {
        guard let first = row(at: minY), let last = row(at: maxY) else { return 0..<0 }
        return first..<(last + 1)
    }

    package func headerRow(ofFile file: Int) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].file < file { low = middle + 1 } else { high = middle }
        }
        return low < rows.count && rows[low].file == file ? low : nil
    }

    /// The first hunk (or file, when `files` is true) that starts below `y`. By position, not
    /// row order: a hidden hunk header has no height and shares its first line's top, so from
    /// that line the header would count as the previous stop and `p` would stay put.
    package func nextStop(below y: Double, files: Bool) -> Int? {
        rows.indices.first { isStop($0, files: files) && top(of: $0) > y }
    }

    package func previousStop(above y: Double, files: Bool) -> Int? {
        rows.indices.last { isStop($0, files: files) && top(of: $0) < y }
    }

    private func isStop(_ index: Int, files: Bool) -> Bool {
        files ? rows[index].isFileHeader : rows[index].isHunkHeader
    }

    package static func columns(_ row: DiffRow) -> Int {
        switch row {
        case .line(_, let line): line.text.count
        case .split(_, let left, let right): max(left?.text.count ?? 0, right?.text.count ?? 0)
        case .hunkHeader(_, _, .titled(let text)), .notice(_, let text): text.count
        case .gap(_, let gap): DiffRowBuilder.gapLabel(gap).text.count
        case .thread(_, let marker): marker.text.count
        case .fileHeader, .image, .hunkHeader, .draft, .openThread: 0
        }
    }
}

extension DiffLayout {
    package func anchor(atY y: Double, paths: [String]) -> ScrollAnchor? {
        guard let index = row(at: y), rows[index].file < paths.count else { return nil }
        let row = rows[index]
        let (line, isOld) = Self.lineNumber(row)
        return ScrollAnchor(
            path: paths[row.file], line: line, isOldSide: isOld, offset: y - top(of: index))
    }

    /// The y offset that shows `anchor` where it was: the same line if it still exists, else the
    /// nearest following line in the same file, else the file's header.
    package func y(for anchor: ScrollAnchor, paths: [String]) -> Double? {
        guard let file = paths.firstIndex(of: anchor.path), let header = headerRow(ofFile: file)
        else {
            return nil
        }
        guard let line = anchor.line else { return top(of: header) + anchor.offset }
        var best: Int?
        for index in header..<rows.count {
            guard rows[index].file == file else { break }
            let (number, isOld) = Self.lineNumber(rows[index])
            guard let number, isOld == anchor.isOldSide else { continue }
            if number == line { return top(of: index) + anchor.offset }
            if number > line, best == nil { best = index }
        }
        return top(of: best ?? header)
    }

    /// The row showing `line` of the file: on the old side for a removed line, else the new.
    package func row(forLine line: Int, inFile file: Int, isOld: Bool) -> Int? {
        guard let header = headerRow(ofFile: file) else { return nil }
        for index in header..<rows.count {
            guard rows[index].file == file else { break }
            switch rows[index] {
            case .line(_, let shown):
                if isOld ? shown.new == nil && shown.old == line : shown.new == line {
                    return index
                }
            case .split(_, let left, let right):
                if isOld ? left?.number == line : right?.number == line { return index }
            default: continue
            }
        }
        return nil
    }

    /// The first new-side line at or after `row` in the same file, for opening the file as it is
    /// now: a header reads as the hunk below it, a removed line as the next line that exists.
    /// Line 1 when the file has none (a deleted file).
    package func location(atOrAfter row: Int) -> (file: Int, line: Int)? {
        guard rows.indices.contains(row) else { return nil }
        let file = rows[row].file
        for index in row..<rows.count {
            guard rows[index].file == file else { break }
            let (number, isOld) = Self.lineNumber(rows[index])
            if let number, !isOld { return (file, number) }
        }
        return (file, 1)
    }

    /// The first row from `row` on, within its file, that shows a line; else `row` itself.
    package func numberedRow(atOrAfter row: Int) -> Int {
        guard rows.indices.contains(row) else { return row }
        for index in row..<rows.count {
            guard rows[index].file == rows[row].file else { break }
            if Self.lineNumber(rows[index]).0 != nil { return index }
        }
        return row
    }

    private static func lineNumber(_ row: DiffRow) -> (Int?, Bool) {
        switch row {
        case .line(_, let line):
            if let new = line.new { (new, false) } else { (line.old, true) }
        case .split(_, let left, let right):
            if let right { (right.number, false) } else { (left?.number, true) }
        default: (nil, false)
        }
    }
}

/// A text position: a row, and a character offset within one side's text.
package struct TextPosition: Comparable, Sendable {
    package var row: Int
    package var column: Int

    package init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    package static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A selection stays within one side in split mode (SPEC §7.4).
package struct DiffSelection: Equatable, Sendable {
    package var side: DiffSide
    package var anchor: TextPosition
    package var head: TextPosition

    package init(side: DiffSide, anchor: TextPosition, head: TextPosition) {
        self.side = side
        self.anchor = anchor
        self.head = head
    }

    package var start: TextPosition { min(anchor, head) }
    package var end: TextPosition { max(anchor, head) }
    package var isEmpty: Bool { anchor == head }

    /// The selected columns of `row`, or nil when the row is outside the selection.
    package func columns(inRow row: Int, length: Int) -> Range<Int>? {
        guard row >= start.row, row <= end.row else { return nil }
        let from = row == start.row ? min(start.column, length) : 0
        let to = row == end.row ? min(end.column, length) : length
        return from..<max(from, to)
    }
}

extension DiffLayout {
    /// The text a side shows in `row`, if it shows any.
    package func text(of row: Int, side: DiffSide) -> String? {
        switch (rows[row], side) {
        case (.line(_, let line), .unified): line.text
        case (.split(_, let left, _), .left): left?.text
        case (.split(_, _, let right), .right): right?.text
        default: nil
        }
    }

    /// The columns a double click at `position` selects: the run of letters, digits and
    /// underscores around it, else the one character there.
    package func word(at position: TextPosition, side: DiffSide) -> Range<Int> {
        let characters = Array(text(of: position.row, side: side) ?? "")
        func isWord(_ index: Int) -> Bool {
            characters.indices.contains(index)
                && (characters[index].isLetter || characters[index].isNumber
                    || characters[index] == "_")
        }
        var start = position.column
        var end = position.column
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        if start == end, end < characters.count { end += 1 }
        return start..<end
    }

    /// Copy text: selected lines of the selection's side, joined with newlines. Rows where that
    /// side has no line (headers, the empty half of an unpaired line) are skipped.
    package func text(of selection: DiffSelection) -> String {
        guard !selection.isEmpty, selection.end.row < rows.count else { return "" }
        var lines: [Substring] = []
        for row in selection.start.row...selection.end.row {
            guard let text = text(of: row, side: selection.side),
                let range = selection.columns(inRow: row, length: text.count)
            else { continue }
            let from = text.index(text.startIndex, offsetBy: range.lowerBound)
            let to = text.index(text.startIndex, offsetBy: range.upperBound)
            lines.append(text[from..<to])
        }
        let joined = lines.joined(separator: "\n")
        let endsAtLineEnd =
            selection.end.column > (text(of: selection.end.row, side: selection.side)?.count ?? 0)
        return endsAtLineEnd ? joined + "\n" : joined
    }
}
