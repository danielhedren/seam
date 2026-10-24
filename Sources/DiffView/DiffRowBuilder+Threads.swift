import SeamCore

extension DiffRowBuilder {
    /// The number a row shows on one side of the file, for placing threads.
    static func number(of row: DiffRow, on side: ThreadAnchor.Side) -> Int? {
        switch (row, side) {
        case (.line(_, let line), .new): line.new
        case (.line(_, let line), .old): line.old
        case (.split(_, _, let right), .new): right?.number
        case (.split(_, let left, _), .old): left?.number
        default: nil
        }
    }

    /// Each thread's row goes after the row showing its last line. A thread whose last line
    /// isn't shown (in a hidden gap, or a collapsed file) gets no row; the panel still lists it.
    static func insertingThreads(
        _ markers: [ThreadMarker], into rows: [DiffRow], file: Int, open: String? = nil
    ) -> [DiffRow] {
        guard !markers.isEmpty else { return rows }
        var result: [DiffRow] = []
        result.reserveCapacity(rows.count + markers.count)
        var placed = Set<String>()
        for row in rows {
            result.append(row)
            for marker in markers where !placed.contains(marker.id) {
                guard number(of: row, on: marker.side) == marker.lines.upperBound else { continue }
                result.append(
                    marker.id == open
                        ? .openThread(file: file, marker) : .thread(file: file, marker))
                placed.insert(marker.id)
            }
        }
        return result
    }

    /// A draft's composer goes after the row showing its last line, below that line's threads.
    /// Like a thread, it gets no row when its last line isn't shown.
    static func insertingDraft(_ draft: DraftMarker, into rows: [DiffRow], file: Int) -> [DiffRow] {
        guard
            var index = rows.firstIndex(where: {
                number(of: $0, on: draft.side) == draft.lines.upperBound
            })
        else { return rows }
        index += 1
        while index < rows.count, rows[index].isThread { index += 1 }
        var result = rows
        result.insert(.draft(file: file, draft), at: index)
        return result
    }

    /// The rows inside a thread's range, with the side the range is on and whose threads they
    /// are, for the gutter mark.
    static func threadedRows(_ rows: [DiffRow], paths: [String], threads: [String: [ThreadMarker]])
        -> [Int: Set<ThreadMark>]
    {
        guard !threads.isEmpty else { return [:] }
        var marked: [Int: Set<ThreadMark>] = [:]
        for (index, row) in rows.enumerated() where row.file < paths.count {
            for marker in threads[paths[row.file]] ?? [] {
                if let number = number(of: row, on: marker.side), marker.lines.contains(number) {
                    marked[index, default: []].insert(
                        ThreadMark(side: marker.side, source: marker.source, isNote: marker.isNote))
                }
            }
        }
        return marked
    }
}

struct ThreadMark: Hashable {
    var side: ThreadAnchor.Side
    var source: ThreadSource
    var isNote = false
}
