import AppKit
import GitKit
import SeamCore
import Testing

@testable import DiffView

/// a.txt: line 2 replaced by two lines, so new 2-3 are added and old 2 is removed.
private func review() -> ReviewDiff {
    var hunk = Hunk(oldStart: 1, oldCount: 3, newStart: 1, newCount: 4, section: "")
    hunk.lines = [
        DiffLine(kind: .context, text: "one", oldNumber: 1, newNumber: 1),
        DiffLine(kind: .removed, text: "two", oldNumber: 2, newNumber: nil),
        DiffLine(kind: .added, text: "two a", oldNumber: nil, newNumber: 2),
        DiffLine(kind: .added, text: "two b", oldNumber: nil, newNumber: 3),
        DiffLine(kind: .context, text: "three", oldNumber: 3, newNumber: 4),
    ]
    var file = FileDiff(oldPath: "a.txt", newPath: "a.txt", status: .modified)
    file.hunks = [hunk]
    return ReviewDiff(scope: .all, files: [ReviewFile(diff: file)])
}

private func marker(_ id: String, _ side: ThreadAnchor.Side, _ lines: ClosedRange<Int>)
    -> ThreadMarker
{
    ThreadMarker(
        id: id, side: side, lines: lines, latestAuthor: "you", latest: "Why?", commentCount: 1,
        isResolved: false)
}

private func texts(_ rows: [DiffRow]) -> [String] {
    rows.compactMap {
        switch $0 {
        case .line(_, let line): line.text
        case .split(_, let left, let right): right?.text ?? left?.text
        case .thread(_, let marker): "[\(marker.id)]"
        default: nil
        }
    }
}

@Suite struct ThreadRowTests {
    @Test(arguments: [DiffLayoutMode.unified, .split])
    func aThreadRowFollowsTheLastLineOfItsRange(mode: DiffLayoutMode) {
        let threads = ["a.txt": [marker("new", .new, 2...3), marker("old", .old, 2...2)]]
        let rows = DiffRowBuilder.rows(
            for: DiffContent(review: review(), mode: mode, threads: threads))
        let shown = texts(rows)
        let after = { (id: String) in shown.firstIndex(of: "[\(id)]").map { shown[$0 - 1] } }
        #expect(after("new") == "two b")
        // Split mode pairs old 2 with new 2 on one row, so the old thread follows that row.
        #expect(after("old") == (mode == .unified ? "two" : "two a"))
    }

    @Test func aThreadOnLinesNotShownGetsNoRow() {
        let threads = ["a.txt": [marker("far", .new, 40...41)]]
        let rows = DiffRowBuilder.rows(for: DiffContent(review: review(), threads: threads))
        #expect(!texts(rows).contains("[far]"))
        let collapsed = DiffRowBuilder.rows(
            for: DiffContent(
                review: review(), collapsed: ["a.txt"],
                threads: ["a.txt": [marker("x", .new, 1...1)]]
            ))
        #expect(collapsed.count == 1)
    }

    @Test func linesInsideARangeAreMarkedOnTheirSide() {
        let threads = ["a.txt": [marker("t", .new, 2...3)]]
        let rows = DiffRowBuilder.rows(for: DiffContent(review: review(), threads: threads))
        let marked = DiffRowBuilder.threadedRows(rows, paths: ["a.txt"], threads: threads)
        #expect(Set(marked.keys.map { texts([rows[$0]]).first ?? "" }) == ["two a", "two b"])
        #expect(marked.values.allSatisfy { $0 == [.new] })
    }

    @MainActor
    @Test func aCommentGoesOnTheSelectedLinesNewSideFirst() throws {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.show(DiffContent(review: review()), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        func row(_ text: String) throws -> Int {
            try #require(canvas.layout.rows.firstIndex { texts([$0]) == [text] })
        }
        func select(_ from: String, _ to: String) throws {
            canvas.selection = DiffSelection(
                side: .unified, anchor: TextPosition(row: try row(from), column: 0),
                head: TextPosition(row: try row(to), column: 2))
        }

        try select("two", "two b")
        #expect(view.commentTarget.map { "\($0.path) \($0.side) \($0.lines)" } == "a.txt new 2...3")
        try select("two", "two")
        #expect(view.commentTarget.map { "\($0.side) \($0.lines)" } == "old 2...2")
    }
}
