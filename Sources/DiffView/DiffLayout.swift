import Foundation
import GitKit

/// Row positions as prefix sums of row heights (SPEC §8.5). Pure, so hit testing, navigation and
/// scroll anchoring are unit tested without a window.
public struct DiffLayout: Equatable, Sendable {
    public struct Metrics: Equatable, Sendable {
        public var lineHeight: Double
        public var fileHeaderHeight: Double
        public var characterWidth: Double

        public init(lineHeight: Double, fileHeaderHeight: Double, characterWidth: Double) {
            self.lineHeight = lineHeight
            self.fileHeaderHeight = fileHeaderHeight
            self.characterWidth = characterWidth
        }
    }

    public let rows: [DiffRow]
    public let metrics: Metrics
    /// `offsets[i]` is the top of row `i`; the last element is the total height.
    private let offsets: [Double]
    /// The longest text in characters, for the document width.
    public let maxColumns: Int

    public init(rows: [DiffRow], metrics: Metrics) {
        self.rows = rows
        self.metrics = metrics
        var offsets = [Double]()
        offsets.reserveCapacity(rows.count + 1)
        var y = 0.0
        var columns = 0
        for row in rows {
            offsets.append(y)
            y += row.isFileHeader ? metrics.fileHeaderHeight : metrics.lineHeight
            columns = max(columns, Self.columns(row))
        }
        offsets.append(y)
        self.offsets = offsets
        maxColumns = columns
    }

    public var totalHeight: Double { offsets.last ?? 0 }

    public func top(of row: Int) -> Double { offsets[min(max(row, 0), rows.count)] }

    public func height(of row: Int) -> Double { top(of: row + 1) - top(of: row) }

    /// The row containing `y`, clamped to the rows that exist; nil when there are none.
    public func row(at y: Double) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    public func rows(in minY: Double, _ maxY: Double) -> Range<Int> {
        guard let first = row(at: minY), let last = row(at: maxY) else { return 0..<0 }
        return first..<(last + 1)
    }

    public func headerRow(ofFile file: Int) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].file < file { low = middle + 1 } else { high = middle }
        }
        return low < rows.count && rows[low].file == file ? low : nil
    }

    /// The first row after `row` that starts a hunk (or a file, when `files` is true).
    public func nextStop(after row: Int, files: Bool) -> Int? {
        rows.indices.dropFirst(row + 1).first { isStop($0, files: files) }
    }

    public func previousStop(before row: Int, files: Bool) -> Int? {
        rows.indices.prefix(max(row, 0)).last { isStop($0, files: files) }
    }

    private func isStop(_ index: Int, files: Bool) -> Bool {
        files ? rows[index].isFileHeader : rows[index].isHunkHeader
    }

    private static func columns(_ row: DiffRow) -> Int {
        switch row {
        case .line(_, _, _, _, let text, _): text.count
        case .split(_, let left, let right): max(left?.text.count ?? 0, right?.text.count ?? 0)
        case .hunkHeader(_, _, let text), .notice(_, let text): text.count
        case .fileHeader: 0
        }
    }
}

/// Where the reader is, in terms that survive a reload: a file and a line in it.
public struct ScrollAnchor: Equatable, Sendable {
    public var path: String
    /// New-side line number at the top of the view, or the old side for a deleted line.
    public var line: Int?
    public var isOldSide = false
    /// How far the top of the view sits below the top of the anchored row.
    public var offset: Double

    public init(path: String, line: Int?, isOldSide: Bool = false, offset: Double) {
        self.path = path
        self.line = line
        self.isOldSide = isOldSide
        self.offset = offset
    }
}

extension DiffLayout {
    public func anchor(atY y: Double, paths: [String]) -> ScrollAnchor? {
        guard let index = row(at: y), rows[index].file < paths.count else { return nil }
        let row = rows[index]
        let (line, isOld) = Self.lineNumber(row)
        return ScrollAnchor(
            path: paths[row.file], line: line, isOldSide: isOld, offset: y - top(of: index))
    }

    /// The y offset that shows `anchor` where it was: the same line if it still exists, else the
    /// nearest following line in the same file, else the file's header.
    public func y(for anchor: ScrollAnchor, paths: [String]) -> Double? {
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

    private static func lineNumber(_ row: DiffRow) -> (Int?, Bool) {
        switch row {
        case .line(_, let old, let new, _, _, _):
            if let new { (new, false) } else { (old, true) }
        case .split(_, let left, let right):
            if let right { (right.number, false) } else { (left?.number, true) }
        default: (nil, false)
        }
    }
}

/// A text position: a row, and a character offset within one side's text.
public struct TextPosition: Comparable, Sendable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A selection stays within one side in split mode (SPEC §7.4).
public struct DiffSelection: Equatable, Sendable {
    public var side: DiffSide
    public var anchor: TextPosition
    public var head: TextPosition

    public init(side: DiffSide, anchor: TextPosition, head: TextPosition) {
        self.side = side
        self.anchor = anchor
        self.head = head
    }

    public var start: TextPosition { min(anchor, head) }
    public var end: TextPosition { max(anchor, head) }
    public var isEmpty: Bool { anchor == head }

    /// The selected columns of `row`, or nil when the row is outside the selection.
    public func columns(inRow row: Int, length: Int) -> Range<Int>? {
        guard row >= start.row, row <= end.row else { return nil }
        let from = row == start.row ? min(start.column, length) : 0
        let to = row == end.row ? min(end.column, length) : length
        return from..<max(from, to)
    }
}

extension DiffLayout {
    /// The text a side shows in `row`, if it shows any.
    public func text(of row: Int, side: DiffSide) -> String? {
        switch (rows[row], side) {
        case (.line(_, _, _, _, let text, _), .unified): text
        case (.split(_, let left, _), .left): left?.text
        case (.split(_, _, let right), .right): right?.text
        default: nil
        }
    }

    /// Copy text: selected lines of the selection's side, joined with newlines. Rows where that
    /// side has no line (headers, the empty half of an unpaired line) are skipped.
    public func text(of selection: DiffSelection) -> String {
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
