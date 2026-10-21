import Foundation
import GitKit

/// Row positions as prefix sums of row heights (SPEC §8.5). Pure, so hit testing, navigation and
/// scroll anchoring are unit tested without a window.
struct DiffLayout: Equatable, Sendable {
    struct Metrics: Equatable, Sendable {
        var lineHeight: Double
        var fileHeaderHeight: Double
        var characterWidth: Double
        var imageHeight = 240.0
    }

    let rows: [DiffRow]
    let metrics: Metrics
    /// `offsets[i]` is the top of row `i`; the last element is the total height.
    private let offsets: [Double]
    /// The longest text in characters, for the document width.
    let maxColumns: Int
    /// Characters per visual line when wrapping; nil when lines don't wrap.
    let wrapColumns: Int?

    init(rows: [DiffRow], metrics: Metrics, wrapColumns: Int? = nil) {
        self.rows = rows
        self.metrics = metrics
        self.wrapColumns = wrapColumns
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

    var totalHeight: Double { offsets.last ?? 0 }

    /// Monospaced text wraps at a fixed column, so a row's height follows from its length.
    static func visualLines(_ count: Int, _ wrapColumns: Int?) -> Int {
        guard let wrapColumns, wrapColumns > 0, count > wrapColumns else { return 1 }
        return (count + wrapColumns - 1) / wrapColumns
    }

    /// `range` cut at each wrap point: the visual line of each piece and its columns within it.
    static func segments(_ range: Range<Int>, wrapColumns: Int?) -> [(
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

    func top(of row: Int) -> Double { offsets[min(max(row, 0), rows.count)] }

    func height(of row: Int) -> Double { top(of: row + 1) - top(of: row) }

    /// The row containing `y`, clamped to the rows that exist; nil when there are none.
    func row(at y: Double) -> Int? {
        guard !rows.isEmpty else { return nil }
        var low = 0
        var high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func rows(in minY: Double, _ maxY: Double) -> Range<Int> {
        guard let first = row(at: minY), let last = row(at: maxY) else { return 0..<0 }
        return first..<(last + 1)
    }

    func headerRow(ofFile file: Int) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].file < file { low = middle + 1 } else { high = middle }
        }
        return low < rows.count && rows[low].file == file ? low : nil
    }

    /// The first row after `row` that starts a hunk (or a file, when `files` is true).
    func nextStop(after row: Int, files: Bool) -> Int? {
        rows.indices.dropFirst(row + 1).first { isStop($0, files: files) }
    }

    func previousStop(before row: Int, files: Bool) -> Int? {
        rows.indices.prefix(max(row, 0)).last { isStop($0, files: files) }
    }

    private func isStop(_ index: Int, files: Bool) -> Bool {
        files ? rows[index].isFileHeader : rows[index].isHunkHeader
    }

    static func columns(_ row: DiffRow) -> Int {
        switch row {
        case .line(_, let line): line.text.count
        case .split(_, let left, let right): max(left?.text.count ?? 0, right?.text.count ?? 0)
        case .hunkHeader(_, _, let text), .notice(_, let text): text.count
        case .gap(_, let gap): DiffRowBuilder.gapLabel(gap).text.count
        case .fileHeader, .image: 0
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
    func anchor(atY y: Double, paths: [String]) -> ScrollAnchor? {
        guard let index = row(at: y), rows[index].file < paths.count else { return nil }
        let row = rows[index]
        let (line, isOld) = Self.lineNumber(row)
        return ScrollAnchor(
            path: paths[row.file], line: line, isOldSide: isOld, offset: y - top(of: index))
    }

    /// The y offset that shows `anchor` where it was: the same line if it still exists, else the
    /// nearest following line in the same file, else the file's header.
    func y(for anchor: ScrollAnchor, paths: [String]) -> Double? {
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
        case .line(_, let line):
            if let new = line.new { (new, false) } else { (line.old, true) }
        case .split(_, let left, let right):
            if let right { (right.number, false) } else { (left?.number, true) }
        default: (nil, false)
        }
    }
}

/// A text position: a row, and a character offset within one side's text.
struct TextPosition: Comparable, Sendable {
    var row: Int
    var column: Int

    static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// A selection stays within one side in split mode (SPEC §7.4).
struct DiffSelection: Equatable, Sendable {
    var side: DiffSide
    var anchor: TextPosition
    var head: TextPosition

    init(side: DiffSide, anchor: TextPosition, head: TextPosition) {
        self.side = side
        self.anchor = anchor
        self.head = head
    }

    var start: TextPosition { min(anchor, head) }
    var end: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }

    /// The selected columns of `row`, or nil when the row is outside the selection.
    func columns(inRow row: Int, length: Int) -> Range<Int>? {
        guard row >= start.row, row <= end.row else { return nil }
        let from = row == start.row ? min(start.column, length) : 0
        let to = row == end.row ? min(end.column, length) : length
        return from..<max(from, to)
    }
}

extension DiffLayout {
    /// The text a side shows in `row`, if it shows any.
    func text(of row: Int, side: DiffSide) -> String? {
        switch (rows[row], side) {
        case (.line(_, let line), .unified): line.text
        case (.split(_, let left, _), .left): left?.text
        case (.split(_, _, let right), .right): right?.text
        default: nil
        }
    }

    /// Copy text: selected lines of the selection's side, joined with newlines. Rows where that
    /// side has no line (headers, the empty half of an unpaired line) are skipped.
    func text(of selection: DiffSelection) -> String {
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
