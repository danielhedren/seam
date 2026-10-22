import AppKit
import GitKit
import SeamCore
import SnapshotTesting
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

private func texts(_ rows: [DiffRow]) -> [String] {
    rows.compactMap {
        switch $0 {
        case .line(_, let line): line.text
        case .thread(_, let marker): "[\(marker.id)]"
        case .draft: "[draft]"
        default: nil
        }
    }
}

@MainActor @Suite struct DraftRowTests {
    private let draft = DraftMarker(path: "a.txt", side: .new, lines: 2...3)

    @Test func theComposerFollowsItsLastLineBelowThatLinesThreads() {
        let thread = ThreadMarker(
            id: "t", side: .new, lines: 3...3, latestAuthor: "you", latest: "Why?",
            commentCount: 1, isResolved: false)
        let rows = DiffRowBuilder.rows(
            for: DiffContent(review: review(), threads: ["a.txt": [thread]], draft: draft))
        #expect(texts(rows) == ["one", "two", "two a", "two b", "[t]", "[draft]", "three"])
        let elsewhere = DiffContent(
            review: review(), draft: DraftMarker(path: "b.txt", side: .new, lines: 1...1))
        #expect(!texts(DiffRowBuilder.rows(for: elsewhere)).contains("[draft]"))
    }

    @Test func aDraftComingOrGoingRebuildsOnlyItsFile() {
        let content = DiffContent(review: review())
        var drafted = content
        drafted.draft = draft
        #expect(DiffCanvasView.spliceableChange(from: content, to: drafted) == [0])
        #expect(DiffCanvasView.spliceableChange(from: drafted, to: content) == [0])
    }

    @Test func theEditorStartsWithTheDraftsTextAndReportsEditsSubmitAndCancel() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let view = DiffScrollView()
        window.contentView = view
        var edits: [String] = []
        var submits = 0
        var cancels = 0
        view.draftText = { "Half" }
        view.onDraftChange = { edits.append($0) }
        view.onDraftSubmit = { submits += 1 }
        view.onDraftCancel = { cancels += 1 }

        view.show(DiffContent(review: review(), draft: draft), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        let editor = try #require(canvas.subviews.compactMap { $0 as? DraftEditor }.first)
        #expect(editor.textView.string == "Half")
        #expect(window.firstResponder === editor.textView)
        let row = try #require(canvas.draftRow)
        let rowTop = canvas.layout.top(of: row)
        #expect(editor.frame.minY > rowTop)
        #expect(editor.frame.maxY < rowTop + canvas.layout.height(of: row))

        editor.textView.insertText(" a thought", replacementRange: editor.textView.selectedRange())
        #expect(edits.last == "Half a thought")
        let submit = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(editor.textView.performKeyEquivalent(with: submit))
        #expect(submits == 1)
        editor.textView.cancelOperation(nil)
        #expect(cancels == 1)

        view.show(DiffContent(review: review()), position: .keep)
        #expect(canvas.subviews.compactMap { $0 as? DraftEditor }.isEmpty)
        #expect(window.firstResponder === canvas)
    }

    @Test func theLinesCWouldCommentOnAreMarkedAsAreTheOpenDrafts() throws {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        view.show(DiffContent(review: review()), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        func row(_ text: String) throws -> Int {
            try #require(canvas.layout.rows.firstIndex { texts([$0]) == [text] })
        }
        func marked() -> [String: ThreadAnchor.Side] {
            Dictionary(
                uniqueKeysWithValues: canvas.targetRows.map {
                    (texts([canvas.layout.rows[$0.key]]).first ?? "", $0.value)
                })
        }
        #expect(marked().isEmpty)

        canvas.selection = DiffSelection(
            side: .unified, anchor: TextPosition(row: try row("two"), column: 0),
            head: TextPosition(row: try row("two b"), column: 2))
        #expect(marked() == ["two a": .new, "two b": .new])
        let caret = TextPosition(row: try row("two"), column: 1)
        canvas.selection = DiffSelection(side: .unified, anchor: caret, head: caret)
        #expect(marked() == ["two": .old])

        view.show(
            DiffContent(
                review: review(), draft: DraftMarker(path: "a.txt", side: .new, lines: 3...4)),
            position: .keep)
        #expect(marked() == ["two b": .new, "three": .new])
    }

    @Test func escapeInTheDiffDropsTheSelectionAndItsMarks() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
            backing: .buffered, defer: false)
        let view = DiffScrollView()
        window.contentView = view
        view.show(DiffContent(review: review()), position: .top)
        let canvas = try #require(view.documentView as? DiffCanvasView)
        let row = try #require(canvas.layout.rows.firstIndex { texts([$0]) == ["two a"] })
        let caret = TextPosition(row: row, column: 1)
        canvas.selection = DiffSelection(side: .unified, anchor: caret, head: caret)
        #expect(!canvas.targetRows.isEmpty)

        let escape = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: escape)

        #expect(canvas.selection == nil)
        #expect(canvas.targetRows.isEmpty)
    }

    @Test(arguments: [DiffLayoutMode.unified, .split])
    func theComposerSitsInItsColumn(mode: DiffLayoutMode) {
        let view = DiffScrollView()
        view.appearance = NSAppearance(named: .aqua)
        view.scrollerStyle = .overlay
        view.increaseContrastOverride = false
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        view.draftText = { "Why two lines?" }
        view.show(DiffContent(review: review(), mode: mode, draft: draft), position: .top)
        view.layoutSubtreeIfNeeded()
        let os = "macOS\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        assertSnapshot(of: view, as: .image, named: "draft-\(mode)-\(os)")
    }
}
