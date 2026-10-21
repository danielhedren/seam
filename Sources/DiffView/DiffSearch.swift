import Foundation

/// One occurrence of the find query: a row, the side it's on, and its characters.
struct DiffMatch: Equatable, Sendable {
    var row: Int
    var side: DiffSide
    var range: Range<Int>
}

/// Find in the diff (SPEC §8.5), on the row model rather than on a text storage.
enum DiffSearch {
    /// Every occurrence of `query` in line text, ignoring case and diacritics, in reading order:
    /// row by row, left side before right.
    static func matches(_ query: String, in layout: DiffLayout) -> [DiffMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [DiffMatch] = []
        for row in layout.rows.indices {
            for side in [DiffSide.unified, .left, .right] {
                guard let text = layout.text(of: row, side: side) else { continue }
                var searchStart = text.startIndex
                while let found = text.range(
                    of: query, options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<text.endIndex)
                {
                    let lower = text.distance(from: text.startIndex, to: found.lowerBound)
                    let upper = text.distance(from: text.startIndex, to: found.upperBound)
                    matches.append(DiffMatch(row: row, side: side, range: lower..<upper))
                    searchStart = found.upperBound
                }
            }
        }
        return matches
    }

    /// The match to show after the content changed: the first one at or after `row`.
    static func nearest(to row: Int, in matches: [DiffMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.row >= row } ?? matches.count - 1
    }
}
