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
    static func insertingThreads(_ markers: [ThreadMarker], into rows: [DiffRow], file: Int)
        -> [DiffRow]
    {
        guard !markers.isEmpty else { return rows }
        var result: [DiffRow] = []
        result.reserveCapacity(rows.count + markers.count)
        var placed = Set<String>()
        for row in rows {
            result.append(row)
            for marker in markers where !placed.contains(marker.id) {
                guard number(of: row, on: marker.side) == marker.lines.upperBound else { continue }
                result.append(.thread(file: file, marker))
                placed.insert(marker.id)
            }
        }
        return result
    }

    /// The rows inside a thread's range, and the side the range is on, for the gutter mark.
    static func threadedRows(_ rows: [DiffRow], paths: [String], threads: [String: [ThreadMarker]])
        -> [Int: Set<ThreadAnchor.Side>]
    {
        guard !threads.isEmpty else { return [:] }
        var marked: [Int: Set<ThreadAnchor.Side>] = [:]
        for (index, row) in rows.enumerated() where row.file < paths.count {
            for marker in threads[paths[row.file]] ?? [] {
                if let number = number(of: row, on: marker.side), marker.lines.contains(number) {
                    marked[index, default: []].insert(marker.side)
                }
            }
        }
        return marked
    }
}
