import Observation
import SeamCore

/// Find in the diff (SPEC §8.5): the bar, its query, and "current of total".
@MainActor
@Observable
package final class FindState {
    package var isShown = false
    /// Searches whenever it changes, typed or filled in from a selection before the bar exists.
    package var query = "" {
        didSet { if query != oldValue { onQueryChange?() } }
    }
    /// The session decides what the diff highlights: this query, or the search's.
    @ObservationIgnored var onQueryChange: (() -> Void)?
    package var result: (current: Int?, total: Int) = (nil, 0)
    /// Bumped by Edit › Find while the bar is already open, to focus its field again.
    package private(set) var focusRequests = 0

    @ObservationIgnored private let diff: DiffController

    init(diff: DiffController) {
        self.diff = diff
    }

    /// ⌘F starts from the diff's selection, as text views do.
    package func show() {
        if let query = diff.selectedText.flatMap(Self.query) { self.query = query }
        isShown = true
        focusRequests += 1
    }

    /// A search field holds one line: the selection's first, without surrounding spaces.
    package nonisolated static func query(from selection: String) -> String? {
        guard let line = selection.split(whereSeparator: \.isNewline).first else { return nil }
        let query = line.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? nil : query
    }

    package func close() {
        isShown = false
        query = ""
        diff.focus()
    }

    package func move(by step: Int) {
        diff.moveToMatch(by: step)
    }
}
