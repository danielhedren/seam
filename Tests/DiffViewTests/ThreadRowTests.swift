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
        #expect(marked.values.allSatisfy { $0 == [ThreadMark(side: .new, source: .seam)] })
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

    @MainActor
    @Test func aRightClickSelectsTheLineUnlessItIsInsideTheSelection() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = view
        view.show(DiffContent(review: review()), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        var menus = 0
        view.menuForLines = {
            menus += 1
            return NSMenu()
        }
        func row(_ text: String) throws -> Int {
            try #require(canvas.layout.rows.firstIndex { texts([$0]) == [text] })
        }
        func rightClick(_ text: String) throws {
            let y = canvas.layout.top(of: try row(text)) + 2
            let point = canvas.convert(NSPoint(x: 120, y: y), to: nil)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            _ = canvas.menu(for: event)
        }

        try rightClick("two a")
        #expect(view.commentTarget.map { "\($0.side) \($0.lines)" } == "new 2...2")

        canvas.selection = DiffSelection(
            side: .unified, anchor: TextPosition(row: try row("two a"), column: 0),
            head: TextPosition(row: try row("two b"), column: 3))
        try rightClick("two b")
        #expect(view.commentTarget.map { "\($0.side) \($0.lines)" } == "new 2...3")
        #expect(menus == 2)
    }

    /// Split rows: one/one, two/two a, —/two b, three/three.
    @MainActor
    @Test func inSideBySideOnlyRemovedLinesGoOnTheOldSide() throws {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        view.show(DiffContent(review: review(), mode: .split), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        let splitRows = canvas.layout.rows.indices.filter {
            if case .split = canvas.layout.rows[$0] { true } else { false }
        }
        func select(_ side: DiffSide, _ first: Int, _ last: Int) -> String? {
            canvas.selection = DiffSelection(
                side: side, anchor: TextPosition(row: splitRows[first], column: 0),
                head: TextPosition(row: splitRows[last], column: 2))
            return view.commentTarget.map { "\($0.side) \($0.lines)" }
        }

        #expect(select(.left, 0, 0) == "new 1...1")
        #expect(select(.left, 1, 1) == "old 2...2")
        #expect(select(.left, 0, 1) == "new 1...1")
        #expect(select(.right, 1, 2) == "new 2...3")
        #expect(select(.right, 0, 3) == "new 1...4")
    }
}

@MainActor @Suite struct ThreadRowDrawingTests {
    /// Side by side, a thread's row is washed only in its own column, the other left empty as
    /// beside an unpaired line, so a long summary can't read as belonging to both sides.
    @Test(arguments: [ThreadAnchor.Side.new, .old])
    func aSplitThreadRowKeepsToItsColumn(side: ThreadAnchor.Side) throws {
        let view = DiffScrollView()
        view.appearance = NSAppearance(named: .aqua)
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let thread = ThreadMarker(
            id: "t", side: side, lines: 2...2, latestAuthor: "you", latest: "Why?",
            commentCount: 1, isResolved: false)
        view.show(
            DiffContent(review: review(), mode: .split, threads: ["a.txt": [thread]]),
            position: .top)
        view.layoutSubtreeIfNeeded()
        let canvas = try #require(view.documentView as? DiffCanvasView)
        let row = try #require(
            canvas.layout.rows.firstIndex { if case .thread = $0 { true } else { false } })
        let rep = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let scale = Double(rep.pixelsWide) / canvas.bounds.width
        let y = Int((canvas.layout.top(of: row) + canvas.layout.height(of: row) / 2) * scale)
        func color(atX x: Double) throws -> NSColor {
            try #require(rep.colorAt(x: Int(x * scale), y: y)?.usingColorSpace(.sRGB))
        }
        let column = canvas.geometry.columnWidth
        let (own, other) =
            side == .new ? (column * 1.9, column * 0.1) : (column * 0.1, column * 1.9)
        let empty = DiffPalette.light.emptySide
        let otherColor = try color(atX: other)
        #expect(abs(otherColor.redComponent - empty.red) < 0.02)
        #expect(abs(otherColor.blueComponent - empty.blue) < 0.02)
        let ownColor = try color(atX: own)
        #expect(ownColor.blueComponent < ownColor.redComponent - 0.05)
    }
}
