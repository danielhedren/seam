import GitKit
import SeamCore
import Testing

@testable import DiffModel

private func line(_ kind: DiffLine.Kind, _ text: String, old: Int?, new: Int?) -> DiffLine {
    DiffLine(kind: kind, text: text, oldNumber: old, newNumber: new)
}

/// a.txt: one hunk replacing two lines with three; b.txt: a pure rename.
private func sampleReview() -> ReviewDiff {
    var hunk = Hunk(oldStart: 1, oldCount: 4, newStart: 1, newCount: 5, section: "func main()")
    hunk.lines = [
        line(.context, "keep", old: 1, new: 1),
        line(.removed, "old one", old: 2, new: nil),
        line(.removed, "old two", old: 3, new: nil),
        line(.added, "new one", old: nil, new: 2),
        line(.added, "new two", old: nil, new: 3),
        line(.added, "new three", old: nil, new: 4),
        line(.context, "tail", old: 4, new: 5),
    ]
    var a = FileDiff(oldPath: "a.txt", newPath: "a.txt", status: .modified)
    a.hunks = [hunk]
    let b = FileDiff(oldPath: "old.txt", newPath: "b.txt", status: .renamed(similarity: 100))
    return ReviewDiff(scope: .all, files: [ReviewFile(diff: a), ReviewFile(diff: b)])
}

/// Names a.txt's hunk, so its header has a height.
private let namedMain = [
    "a.txt": FileSyntax(oldScopes: [SyntaxScope(lines: 0...9, name: "main")])
]

private let metrics = DiffLayout.Metrics(lineHeight: 10, fileHeaderHeight: 20, characterWidth: 7)

@Suite(.timeLimit(.minutes(1))) struct DiffRowBuilderTests {
    @Test func unifiedModeListsEveryLineUnderItsHunkHeader() {
        let rows = DiffRowBuilder.rows(for: sampleReview(), mode: .unified)
        #expect(rows.count == 1 + 1 + 7 + 1 + 1)
        #expect(rows[0] == .fileHeader(file: 0))
        #expect(rows[1] == .hunkHeader(file: 0, hunk: 0, .hidden))
        #expect(
            rows[3]
                == .line(
                    file: 0,
                    UnifiedLine(
                        old: 2, new: nil, kind: .removed, text: "old one", highlights: [0..<3])))
        #expect(rows.last == .notice(file: 1, text: "Renamed without changes"))
    }

    @Test func splitModePairsRemovedRunsWithTheAddedLinesAfterThem() {
        let rows = DiffRowBuilder.rows(for: sampleReview(), mode: .split)
        let pairs: [(Int?, Int?)] = rows.compactMap {
            guard case .split(_, let left, let right) = $0 else { return nil }
            return (left?.number, right?.number)
        }
        #expect(pairs.map(\.0) == [1, 2, 3, nil, 4])
        #expect(pairs.map(\.1) == [1, 2, 3, 4, 5])
    }

    @Test func addedLinesBeforeARemovalAreNotPairedWithIt() {
        let rows = DiffRowBuilder.splitRows(
            [line(.added, "a", old: nil, new: 1), line(.removed, "r", old: 1, new: nil)],
            ["a", "r"], [[], []], file: 0)
        #expect(
            rows == [
                .split(file: 0, left: nil, right: SideLine(kind: .added, number: 1, text: "a")),
                .split(file: 0, left: SideLine(kind: .removed, number: 1, text: "r"), right: nil),
            ])
    }

    @Test func changedWordsAreMarkedOnBothSidesOfAPair() {
        let rows = DiffRowBuilder.rows(for: sampleReview(), mode: .split)
        let pair = rows.compactMap { row -> (SideLine, SideLine)? in
            guard case .split(_, let left?, let right?) = row, left.kind == .removed else {
                return nil
            }
            return (left, right)
        }
        #expect(pair.map(\.0.highlights) == [[0..<3], [0..<3]])
        #expect(pair.map(\.1.highlights) == [[0..<3], [0..<3]])
    }

    @Test func collapsedFilesKeepOnlyTheirHeader() {
        let rows = DiffRowBuilder.rows(for: sampleReview(), mode: .unified, collapsed: ["a.txt"])
        #expect(rows.first == .fileHeader(file: 0))
        #expect(rows[1] == .fileHeader(file: 1))
    }

    @Test func filesWithoutLinesGetANotice() {
        var binary = FileDiff(oldPath: "x.bin", newPath: "x.bin", status: .modified)
        binary.isBinary = true
        var mode = FileDiff(oldPath: "run.sh", newPath: "run.sh", status: .modified)
        mode.oldMode = "100644"
        mode.newMode = "100755"
        let deferred = FileDiff(oldPath: nil, newPath: "big.json", status: .added)
        let review = ReviewDiff(
            scope: .all,
            files: [
                ReviewFile(diff: binary), ReviewFile(diff: mode),
                ReviewFile(diff: deferred, isUntracked: true, isDeferred: true),
            ])
        let notices = DiffRowBuilder.rows(for: review, mode: .unified).compactMap {
            if case .notice(_, let text) = $0 { text } else { nil }
        }
        #expect(
            notices == [
                "Binary file", "Mode changed from 100644 to 100755", "Large file not loaded",
            ])
    }

    @Test func tabsExpandToTheNextStopAndCarriageReturnsShow() {
        #expect(TabStops.expand("a\tb", width: 4) == "a   b")
        #expect(TabStops.expand("\tx", width: 4) == "    x")
        #expect(TabStops.expand("line\r", width: 4) == "line")
        #expect(TabStops.expand("line\r", width: 4, showsReturns: true) == "line␍")
        #expect(TabStops.expand("\tx\r", width: 4) == "    x")
    }
}

@Suite(.timeLimit(.minutes(1))) struct DiffLayoutTests {
    private let layout = DiffLayout(
        rows: DiffRowBuilder.rows(
            for: sampleReview(), mode: .unified,
            syntax: namedMain),
        metrics: metrics)

    @Test func rowTopsArePrefixSumsOfRowHeights() {
        #expect(layout.top(of: 0) == 0)
        #expect(layout.top(of: 1) == 20)
        #expect(layout.top(of: 2) == 30)
        #expect(layout.totalHeight == 20 + 8 * 10 + 20 + 10)
    }

    @Test(arguments: [(-5.0, 0), (0, 0), (19.9, 0), (20, 1), (35, 2), (10_000, 10)])
    func hitTestingFindsTheRowContainingY(y: Double, expected: Int) {
        #expect(layout.row(at: y) == expected)
    }

    @Test func navigationStopsAtHunksAndFiles() {
        #expect(layout.nextStop(below: 0, files: false) == 1)
        #expect(layout.nextStop(below: 20, files: false) == nil)
        #expect(layout.nextStop(below: 0, files: true) == 9)
        #expect(layout.previousStop(above: 100, files: true) == 0)
        #expect(layout.headerRow(ofFile: 1) == 9)
        #expect(layout.headerRow(ofFile: 2) == nil)
    }

    @Test func longestTextSetsTheColumnCount() {
        #expect(layout.maxColumns == "Renamed without changes".count)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ScrollAnchorTests {
    private let paths = ["a.txt", "b.txt"]

    private func layout(_ review: ReviewDiff, _ mode: DiffLayoutMode = .unified) -> DiffLayout {
        DiffLayout(
            rows: DiffRowBuilder.rows(for: review, mode: mode, syntax: namedMain), metrics: metrics)
    }

    @Test func anchorRoundTripsToTheSameLineAndOffset() throws {
        let layout = layout(sampleReview())
        let anchor = try #require(layout.anchor(atY: 73, paths: paths))
        #expect(anchor.path == "a.txt")
        #expect(anchor.line == 3)
        #expect(anchor.offset == 3)
        #expect(layout.y(for: anchor, paths: paths) == 73)
    }

    @Test func reloadWithAFileAddedAboveKeepsTheSameLineInView() throws {
        let before = layout(sampleReview())
        let anchor = try #require(before.anchor(atY: 85, paths: paths))
        var added = FileDiff(oldPath: nil, newPath: "0.txt", status: .added)
        var hunk = Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: 3, section: "")
        hunk.lines = (1...3).map { (number: Int) in line(.added, "\(number)", old: nil, new: number)
        }
        added.hunks = [hunk]
        var review = sampleReview()
        review.files.insert(ReviewFile(diff: added, isUntracked: true), at: 0)
        let after = layout(review)

        let y = try #require(after.y(for: anchor, paths: ["0.txt"] + paths))
        // The new file adds its header and three lines; its unnamed hunk header takes no space.
        #expect(y == 85 + 20 + 30)
        #expect(after.anchor(atY: y, paths: ["0.txt"] + paths) == anchor)
    }

    @Test func vanishedLineFallsBackToTheNextOneInTheFile() {
        let anchor = ScrollAnchor(path: "a.txt", line: 2, offset: 0)
        var review = sampleReview()
        review.files[0].diff.hunks[0].lines.removeAll { $0.newNumber == 2 }
        let layout = layout(review)
        let y = layout.y(for: anchor, paths: paths)
        #expect(y.flatMap { layout.anchor(atY: $0, paths: paths)?.line } == 3)
    }

    @Test func anchorWorksAcrossModes() throws {
        let unified = layout(sampleReview())
        let anchor = try #require(unified.anchor(atY: 85, paths: paths))
        let split = layout(sampleReview(), .split)
        let y = try #require(split.y(for: anchor, paths: paths))
        #expect(split.anchor(atY: y, paths: paths)?.line == anchor.line)
    }

    @Test func aHeaderRowReadsAsTheFirstLineBelowIt() {
        let layout = layout(sampleReview())
        #expect(layout.location(atOrAfter: 1)?.line == 1)
        #expect(layout.location(atOrAfter: 4)?.line == 2)
        #expect(layout.location(atOrAfter: 9)?.file == 1)
        #expect(layout.location(atOrAfter: 9)?.line == 1)
    }

    @Test func missingFileGivesNoPosition() {
        let anchor = ScrollAnchor(path: "gone.txt", line: 1, offset: 0)
        #expect(layout(sampleReview()).y(for: anchor, paths: paths) == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct SelectionTests {
    @Test func unifiedSelectionCopiesPartialFirstAndLastLines() {
        let layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: sampleReview(), mode: .unified), metrics: metrics)
        let selection = DiffSelection(
            side: .unified, anchor: TextPosition(row: 4, column: 4),
            head: TextPosition(row: 2, column: 2))
        #expect(layout.text(of: selection) == "ep\nold one\nold ")
    }

    @Test func splitSelectionStaysOnOneSideAndSkipsGaps() {
        let layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: sampleReview(), mode: .split), metrics: metrics)
        let left = DiffSelection(
            side: .left, anchor: TextPosition(row: 1, column: 0),
            head: TextPosition(row: 6, column: 4))
        let right = DiffSelection(
            side: .right, anchor: TextPosition(row: 3, column: 0),
            head: TextPosition(row: 5, column: 9))
        #expect(layout.text(of: left) == "keep\nold one\nold two\ntail")
        #expect(layout.text(of: right) == "new one\nnew two\nnew three")
    }

    @Test(arguments: [(0, 0..<3), (2, 0..<3), (3, 0..<3), (4, 4..<7), (7, 4..<7)])
    func aDoubleClickSelectsTheWordAroundIt(column: Int, expected: Range<Int>) {
        let layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: sampleReview(), mode: .unified), metrics: metrics)
        let position = TextPosition(row: 3, column: column)
        #expect(layout.word(at: position, side: .unified) == expected)
    }

    @Test func selectingPastTheLineEndIncludesTheNewline() {
        let layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: sampleReview(), mode: .unified), metrics: metrics)
        let selection = DiffSelection(
            side: .unified, anchor: TextPosition(row: 2, column: 0),
            head: TextPosition(row: 2, column: 5))
        #expect(layout.text(of: selection) == "keep\n")
    }
}

@Suite(.timeLimit(.minutes(1))) struct SyntaxRowTests {
    @Test func aHunkHeaderNamesTheDefinitionsAroundItsFirstChange() {
        let scopes = [
            SyntaxScope(lines: 0...9, name: "Handler"), SyntaxScope(lines: 1...2, name: "Setup"),
            SyntaxScope(lines: 2...8, name: "Handle"),
        ]
        let syntax = FileSyntax(newScopes: scopes)
        let rows = DiffRowBuilder.rows(
            for: sampleReview(), mode: .unified, syntax: ["a.txt": FileSyntax(oldScopes: scopes)])

        #expect(rows[1] == .hunkHeader(file: 0, hunk: 0, .titled("Handler › Setup")))
        var added = Hunk(oldStart: 4, oldCount: 1, newStart: 4, newCount: 2, section: "")
        added.lines = [
            DiffLine(kind: .context, text: "a", oldNumber: 4, newNumber: 4),
            DiffLine(kind: .added, text: "b", oldNumber: nil, newNumber: 5),
        ]
        #expect(DiffRowBuilder.header(added, syntax) == "Handler › Handle")
        #expect(DiffRowBuilder.header(added, nil) == "")
    }

    @Test func spansFollowTheirSideAndMoveWithTabExpansion() {
        var hunk = Hunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, section: "")
        hunk.lines = [
            DiffLine(kind: .removed, text: "\tlet a", oldNumber: 1, newNumber: nil),
            DiffLine(kind: .added, text: "\tvar a", oldNumber: nil, newNumber: 1),
        ]
        var file = FileDiff(oldPath: "a.swift", newPath: "a.swift", status: .modified)
        file.hunks = [hunk]
        let syntax = FileSyntax(
            old: [[SyntaxSpan(range: 1..<4, token: .keyword)]],
            new: [[SyntaxSpan(range: 1..<4, token: .string)]])

        let rows = DiffRowBuilder.rows(
            for: ReviewDiff(scope: .all, files: [ReviewFile(diff: file)]), mode: .unified,
            syntax: ["a.swift": syntax])

        let lines = rows.compactMap { row -> UnifiedLine? in
            if case .line(_, let line) = row { line } else { nil }
        }
        #expect(
            lines.map(\.syntax) == [
                [SyntaxSpan(range: 4..<7, token: .keyword)],
                [SyntaxSpan(range: 4..<7, token: .string)],
            ])
    }
}

@Suite(.timeLimit(.minutes(1))) struct WrapTests {
    private func row(_ text: String) -> DiffRow {
        .line(file: 0, UnifiedLine(old: 1, new: 1, kind: .context, text: text))
    }

    @Test func wrappedRowsAreAsTallAsTheirVisualLines() {
        let layout = DiffLayout(
            rows: [row(String(repeating: "x", count: 25)), row("short"), row("")],
            metrics: metrics, wrapColumns: 10)
        #expect(layout.height(of: 0) == 30)
        #expect(layout.height(of: 1) == 10)
        #expect(layout.height(of: 2) == 10)
    }

    @Test func splitRowsTakeTheTallerSide() {
        let rows: [DiffRow] = [
            .split(
                file: 0, left: SideLine(kind: .removed, number: 1, text: "short"),
                right: SideLine(kind: .added, number: 1, text: String(repeating: "y", count: 21)))
        ]
        #expect(DiffLayout(rows: rows, metrics: metrics, wrapColumns: 10).height(of: 0) == 30)
    }

    @Test func withoutWrappingEveryLineIsOneLineTall() {
        let layout = DiffLayout(rows: [row(String(repeating: "x", count: 500))], metrics: metrics)
        #expect(layout.height(of: 0) == 10)
    }

    @Test func rangesAreCutAtEachWrapPoint() {
        let segments = DiffLayout.segments(7..<23, wrapColumns: 10)
        #expect(segments.map(\.line) == [0, 1, 2])
        #expect(segments.map(\.columns) == [7..<10, 0..<10, 0..<3])
        #expect(DiffLayout.segments(3..<5, wrapColumns: nil).map(\.columns) == [3..<5])
    }
}

@Suite(.timeLimit(.minutes(1))) struct DiffSearchTests {
    @Test func matchesIgnoreCaseAndFindEveryOccurrenceInReadingOrder() {
        let layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: sampleReview(), mode: .split), metrics: metrics)
        let matches = DiffSearch.matches("ONE", in: layout)
        #expect(matches.map(\.side) == [.left, .right])
        #expect(matches.map(\.range) == [4..<7, 4..<7])
        #expect(matches[0].row == matches[1].row)
    }

    @Test func severalMatchesOnOneLineAreAllFound() {
        let rows: [DiffRow] = [
            .line(file: 0, UnifiedLine(old: 1, new: 1, kind: .context, text: "a.b.a.b.a"))
        ]
        let matches = DiffSearch.matches("a", in: DiffLayout(rows: rows, metrics: metrics))
        #expect(matches.map(\.range) == [0..<1, 4..<5, 8..<9])
    }

    @Test func headersAndEmptyQueriesMatchNothing() {
        let layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: sampleReview(), mode: .unified), metrics: metrics)
        #expect(DiffSearch.matches("", in: layout).isEmpty)
        #expect(DiffSearch.matches("func main", in: layout).isEmpty)
    }

    @Test func afterAReloadTheNearestMatchAtOrBelowTheOldOneIsCurrent() {
        let matches = [2, 5, 9].map { DiffMatch(row: $0, side: .unified, range: 0..<1) }
        #expect(DiffSearch.nearest(to: 4, in: matches) == 1)
        #expect(DiffSearch.nearest(to: 20, in: matches) == 2)
        #expect(DiffSearch.nearest(to: 0, in: []) == nil)
    }
}
