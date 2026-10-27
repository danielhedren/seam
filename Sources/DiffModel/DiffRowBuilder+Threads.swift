import SeamCore

extension DiffRowBuilder {
    /// The number a row shows on one side of the file, for placing threads.
    package static func number(of row: DiffRow, on side: ThreadAnchor.Side) -> Int? {
        switch (row, side) {
        case (.line(_, let line), .new): line.new
        case (.line(_, let line), .old): line.old
        case (.split(_, _, let right), .new): right?.number
        case (.split(_, let left, _), .old): left?.number
        default: nil
        }
    }

    /// Each thread's row goes after the row showing its last line, or before the first row past
    /// it when that line is hidden in a gap, so no thread goes missing. One without lines in the
    /// diff goes under the file's header.
    static func insertingThreads(
        _ markers: [ThreadMarker], into rows: [DiffRow], file: Int, open: String? = nil
    ) -> [DiffRow] {
        guard !markers.isEmpty else { return rows }
        func row(_ marker: ThreadMarker) -> DiffRow {
            marker.id == open ? .openThread(file: file, marker) : .thread(file: file, marker)
        }
        var result: [DiffRow] = []
        result.reserveCapacity(rows.count + markers.count)
        var pending = markers.filter(\.isOnLines)
        for current in rows {
            pending.removeAll { marker in
                guard let number = number(of: current, on: marker.side),
                    number > marker.lines.upperBound
                else { return false }
                result.append(row(marker))
                return true
            }
            result.append(current)
            if current.isFileHeader {
                result += markers.filter { !$0.isOnLines }.map(row)
            }
            pending.removeAll { marker in
                guard number(of: current, on: marker.side) == marker.lines.upperBound else {
                    return false
                }
                result.append(row(marker))
                return true
            }
        }
        return result + pending.map(row)
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
    package static func threadedRows(
        _ rows: [DiffRow], paths: [String], threads: [String: [ThreadMarker]],
        resolved: [String: [ThreadMarker]] = [:]
    ) -> [Int: Set<ThreadMark>] {
        guard !threads.isEmpty || !resolved.isEmpty else { return [:] }
        var marked: [Int: Set<ThreadMark>] = [:]
        for (index, row) in rows.enumerated() where paths.indices.contains(row.file) {
            let path = paths[row.file]
            for (marker, isResolved) in (threads[path] ?? []).map({ ($0, false) })
                + (resolved[path] ?? []).map({ ($0, true) })
            {
                if let number = number(of: row, on: marker.side), marker.lines.contains(number) {
                    marked[index, default: []].insert(
                        ThreadMark(
                            side: marker.side, source: marker.source, isNote: marker.isNote,
                            isResolved: isResolved))
                }
            }
        }
        return marked
    }
}

package struct ThreadMark: Hashable {
    package var side: ThreadAnchor.Side
    package var source: ThreadSource
    package var isNote = false
    /// A hidden resolved thread's, drawn hollow.
    package var isResolved = false

    package init(
        side: ThreadAnchor.Side, source: ThreadSource, isNote: Bool = false,
        isResolved: Bool = false
    ) {
        self.side = side
        self.source = source
        self.isNote = isNote
        self.isResolved = isResolved
    }
}
