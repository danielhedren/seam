import Foundation
import SeamCore

/// One occurrence of the find query: a row, the side it's on, and its characters.
package struct DiffMatch: Equatable, Sendable {
    package var row: Int
    package var side: DiffSide
    package var range: Range<Int>
}

/// Find in the diff (SPEC §8.5), on the row model rather than on a text storage.
package enum DiffSearch {
    /// Every occurrence of `query` in line text, in reading order: row by row, left side
    /// before right. None for a pattern that doesn't compile.
    package static func matches(_ query: TextQuery, in layout: DiffLayout) -> [DiffMatch] {
        guard let matcher = query.matcher() else { return [] }
        var matches: [DiffMatch] = []
        for row in layout.rows.indices {
            for side in [DiffSide.unified, .left, .right] {
                guard let text = layout.text(of: row, side: side) else { continue }
                for range in matcher.ranges(in: text) {
                    matches.append(DiffMatch(row: row, side: side, range: range))
                }
            }
        }
        return matches
    }

    package static func matches(_ text: String, in layout: DiffLayout) -> [DiffMatch] {
        matches(TextQuery(text), in: layout)
    }

    /// The match to show after the content changed: the first one at or after `row`.
    package static func nearest(to row: Int, in matches: [DiffMatch]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.row >= row } ?? matches.count - 1
    }
}
