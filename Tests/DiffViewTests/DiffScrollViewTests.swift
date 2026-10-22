import AppKit
import GitKit
import SeamCore
import Testing

@testable import DiffView

@MainActor @Suite struct DiffScrollViewTests {
    private func review(_ words: [String]) -> ReviewDiff {
        var hunk = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: words.count, section: "")
        hunk.lines = words.enumerated().map { offset, word in
            DiffLine(kind: .added, text: word, oldNumber: nil, newNumber: offset + 1)
        }
        var file = FileDiff(oldPath: nil, newPath: "a.txt", status: .added)
        file.hunks = [hunk]
        return ReviewDiff(scope: .all, files: [ReviewFile(diff: file)])
    }

    @Test func findReportsMatchesMovesThroughThemAndKeepsThemAcrossAReload() {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        var results: [String] = []
        view.onSearchResult = { current, total in results.append("\(current ?? 0)/\(total)") }
        view.show(DiffContent(review: review(["alpha", "beta", "alpha"])), position: .top)

        view.search("ALPHA")
        view.moveToMatch(by: 1)
        view.moveToMatch(by: 1)
        view.show(
            DiffContent(review: review(["alpha", "alpha", "beta", "alpha"])), position: .keep)
        view.search("gamma")

        #expect(results == ["1/2", "2/2", "1/2", "1/3", "0/0"])
    }

    @Test func theSelectionIsTheTextOnScreen() throws {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.show(DiffContent(review: review(["alpha", "beta"])), position: .top)
        #expect(view.selectedText == nil)

        let canvas = try #require(view.documentView as? DiffCanvasView)
        let row = try #require(
            canvas.layout.rows.firstIndex { if case .line = $0 { true } else { false } })
        canvas.selection = DiffSelection(
            side: .unified, anchor: TextPosition(row: row, column: 1),
            head: TextPosition(row: row, column: 4))

        #expect(view.selectedText == "lph")
    }

    @Test func theDiffTakesFocusInAWindowWhereNothingHasIt() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        let view = DiffScrollView()
        window.contentView = view
        #expect(view.isFocused)

        let field = NSTextField()
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: true)
        other.contentView = NSView()
        other.contentView?.addSubview(field)
        other.makeFirstResponder(field)
        let second = DiffScrollView()
        other.contentView?.addSubview(second)
        #expect(!second.isFocused)
    }

    /// A long line widens the document past the view; the checkbox stays at the view's edge.
    @Test func theViewedCheckboxIsWhereTheStickyHeaderPutsItOnAWideDiff() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView = view
        var toggled: [String] = []
        view.onToggleViewed = { toggled.append("viewed \($0)") }
        view.onToggleCollapse = { toggled.append("collapse \($0)") }
        view.show(
            DiffContent(review: review([String(repeating: "x", count: 300)])), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        #expect(canvas.bounds.width > view.contentSize.width)

        let height = canvas.layout.metrics.fileHeaderHeight
        let header = DiffHeaderDrawing.layout(
            canvas.review.files[0], viewed: .unviewed,
            in: NSRect(x: 0, y: 0, width: view.contentSize.width, height: height),
            font: canvas.font, palette: .light)
        try click(canvas, at: NSPoint(x: header.checkbox.midX, y: header.checkbox.midY))

        #expect(toggled == ["viewed a.txt"])
    }

    @Test func aLongPathLeavesTheCountsAndViewedCheckboxInANarrowHeader() {
        let path = "src/very/long/path/that/keeps/going/and/going/Component.swift"
        var diff = FileDiff(oldPath: path, newPath: path, status: .modified)
        var hunk = Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "")
        hunk.lines = [
            DiffLine(kind: .removed, text: "a", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .added, text: "b", oldNumber: nil, newNumber: 1),
        ]
        diff.hunks = [hunk]
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let rect = NSRect(x: 0, y: 0, width: 360, height: 28)
        let header = DiffHeaderDrawing.layout(
            ReviewFile(diff: diff), viewed: .unviewed, in: rect, font: font, palette: .light)

        #expect(header.viewedFrame.maxX <= rect.maxX)
        let ends = header.pieces.map { $0.x + CTLineGetTypographicBounds($0.line, nil, nil, nil) }
        #expect(ends.allSatisfy { $0 <= rect.maxX })
        #expect(header.pieces.count == 4)
    }

    @Test func aClickJustLeftOfAGapsControlsExpandsNothing() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled],
            backing: .buffered, defer: false)
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView = view
        var expanded: [ExpandDirection] = []
        view.onExpand = { _, _, direction in expanded.append(direction) }
        var content = DiffContent(review: review(["x"]))
        content.review.files[0].diff.hunks[0] = {
            var hunk = Hunk(oldStart: 30, oldCount: 0, newStart: 30, newCount: 1, section: "")
            hunk.lines = [DiffLine(kind: .added, text: "x", oldNumber: nil, newNumber: 30)]
            return hunk
        }()
        let lines = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
        content.contents = ["a.txt": FileContents(new: lines)]
        view.show(content, position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        let gap = try #require(
            canvas.layout.rows.firstIndex { if case .gap = $0 { true } else { false } })
        let y = canvas.layout.top(of: gap) + 2
        let characterWidth = canvas.layout.metrics.characterWidth

        try click(canvas, at: NSPoint(x: canvas.geometry.unifiedTextX - characterWidth / 2, y: y))
        #expect(expanded.isEmpty)
        try click(canvas, at: NSPoint(x: canvas.geometry.unifiedTextX + characterWidth / 2, y: y))
        #expect(expanded == [.up])
    }

    private func click(_ view: NSView, at point: NSPoint) throws {
        let window = try #require(view.window)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
    }

    @Test func collapsingOneFileSplicesTheSameRowsAFullRebuildWouldMake() {
        var content = DiffContent(review: review(["alpha", "beta"]))
        let second = ReviewFile(
            diff: {
                var file = FileDiff(oldPath: nil, newPath: "b.txt", status: .added)
                file.hunks = review(["x"]).files[0].diff.hunks
                return file
            }())
        content.review.files.append(second)
        let canvas = DiffCanvasView()
        canvas.show(content)

        content.collapsed = ["a.txt"]
        #expect(
            DiffCanvasView.spliceableChange(
                from: DiffContent(review: content.review), to: content) == [0])
        canvas.show(content)
        #expect(canvas.layout.rows == DiffRowBuilder.rows(for: content))

        content.collapsed = ["b.txt"]
        canvas.show(content)
        #expect(canvas.layout.rows == DiffRowBuilder.rows(for: content))

        content.mode = .split
        #expect(
            DiffCanvasView.spliceableChange(
                from: DiffContent(review: content.review), to: content) == nil)
    }
}
