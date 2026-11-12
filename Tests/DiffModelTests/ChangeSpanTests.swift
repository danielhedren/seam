import GitKit
import SeamCore
import Testing

@testable import DiffModel

/// Where the changes are, for the change ruler (SPEC §7.4).
@Suite(.timeLimit(.minutes(1))) struct ChangeSpanTests {
    private func line(_ file: Int, _ kind: DiffLine.Kind) -> DiffRow {
        .line(file: file, UnifiedLine(old: 1, new: 1, kind: kind, text: "x"))
    }

    @Test func eachRunOfChangedLinesIsOneSpanAndAViewedFilesAreDimmed() {
        let rows = [
            line(0, .context), line(0, .removed), line(0, .added), line(0, .context),
            line(0, .added), line(1, .added), line(1, .context),
        ]
        let layout = DiffLayout(
            rows: rows, metrics: .init(lineHeight: 10, fileHeaderHeight: 20, characterWidth: 7))

        let spans = layout.changeSpans(viewed: [1])

        let total: Double = 70
        let tops: [Double] = [10 / total, 40 / total, 50 / total]
        let heights: [Double] = [20 / total, 10 / total, 10 / total]
        #expect(spans.map(\.top) == tops)
        #expect(spans.map(\.height) == heights)
        #expect(spans.map(\.isViewed) == [false, false, true])
    }
}
