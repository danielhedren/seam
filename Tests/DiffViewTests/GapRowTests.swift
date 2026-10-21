import GitKit
import SeamCore
import Testing

@testable import DiffView

/// A 100-line file whose line 50 was replaced by two lines, so new numbers are old + 1 below it.
@Suite struct GapRowTests {
    private let path = "big.txt"

    private var content: DiffContent {
        var hunk = Hunk(oldStart: 47, oldCount: 7, newStart: 47, newCount: 8, section: "")
        hunk.lines =
            (47...49).map { (number: Int) in
                DiffLine(
                    kind: .context, text: "line \(number)", oldNumber: number, newNumber: number)
            }
            + [
                DiffLine(kind: .removed, text: "line 50", oldNumber: 50, newNumber: nil),
                DiffLine(kind: .added, text: "line 50a", oldNumber: nil, newNumber: 50),
                DiffLine(kind: .added, text: "line 50b", oldNumber: nil, newNumber: 51),
            ]
            + (51...53).map { (number: Int) in
                DiffLine(
                    kind: .context, text: "line \(number)", oldNumber: number, newNumber: number + 1
                )
            }
        var file = FileDiff(oldPath: path, newPath: path, status: .modified)
        file.hunks = [hunk]
        let new =
            ((1...49).map { "line \($0)" } + ["line 50a", "line 50b"]
            + (51...100).map { "line \($0)" })
            .joined(separator: "\n") + "\n"
        return DiffContent(
            review: ReviewDiff(scope: .all, files: [ReviewFile(diff: file)]),
            contents: [path: FileContents(old: nil, new: new)])
    }

    private func rows(_ expansions: [Int: GapExpansion] = [:]) -> [DiffRow] {
        var content = content
        content.expansions = expansions.isEmpty ? [:] : [path: expansions]
        return DiffRowBuilder.rows(
            for: content.review, mode: .unified, contents: content.contents,
            expansions: content.expansions)
    }

    private func gaps(_ rows: [DiffRow]) -> [GapRow] {
        rows.compactMap { if case .gap(_, let gap) = $0 { gap } else { nil } }
    }

    private func contextNumbers(_ rows: [DiffRow]) -> [(Int?, Int?)] {
        rows.compactMap {
            guard case .line(_, let line) = $0, line.kind == .context else { return nil }
            return (line.old, line.new)
        }
    }

    @Test func hiddenLinesAboveAndBelowTheHunkBecomeGapRows() {
        let gaps = gaps(rows())
        #expect(
            gaps == [
                GapRow(gap: 0, hidden: 46, canExpandDown: false, canExpandUp: true),
                GapRow(gap: 1, hidden: 47, canExpandDown: true, canExpandUp: false),
            ])
    }

    @Test func expandingUpRevealsLinesJustAboveTheHunk() {
        let rows = rows([0: GapExpansion(bottom: 20)])
        #expect(gaps(rows).first?.hidden == 26)
        let revealed = contextNumbers(rows).prefix(20)
        #expect(revealed.first?.0 == 27)
        #expect(revealed.last?.1 == 46)
    }

    @Test func linesBelowTheHunkKeepTheShiftedOldNumbers() {
        let rows = rows([1: GapExpansion(top: 20)])
        let below = contextNumbers(rows).suffix(20)
        #expect(below.first?.0 == 54)
        #expect(below.first?.1 == 55)
        #expect(gaps(rows).last?.hidden == 27)
    }

    @Test func showAllRemovesTheGapRow() {
        let rows = rows([0: .all, 1: .all])
        #expect(gaps(rows).isEmpty)
        #expect(contextNumbers(rows).count == 46 + 6 + 47)
    }

    @Test func filesWithoutLoadedContentsHaveNoGaps() {
        let rows = DiffRowBuilder.rows(for: content.review, mode: .unified)
        #expect(gaps(rows).isEmpty)
    }

    @Test func gapLabelOffersOnlyTheDirectionsThatExist() {
        let first = DiffRowBuilder.gapLabel(
            GapRow(gap: 0, hidden: 5, canExpandDown: false, canExpandUp: true))
        #expect(first.controls.map(\.1) == [.up, .all])
        #expect(first.text.hasPrefix("↑ 5"))
    }
}
