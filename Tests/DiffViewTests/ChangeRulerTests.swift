import AppKit
import Testing

@testable import DiffModel
@testable import DiffView

/// The change ruler's marks (SPEC §7.4).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChangeRulerTests {
    @Test func marksThatNearlyTouchAreDrawnAsOneDimmedOnlyWhenAllOfItIsViewed() {
        let changes = [
            DiffLayout.ChangeSpan(top: 0.10, height: 0.01, isViewed: true),
            DiffLayout.ChangeSpan(top: 0.111, height: 0.01, isViewed: false),
            DiffLayout.ChangeSpan(top: 0.50, height: 0.01, isViewed: true),
        ]

        let rects = ThreadRuler.changeRects(changes, height: 1000)

        #expect(rects.map(\.rect.minY) == [100, 500])
        #expect(rects.map(\.rect.height) == [21, 10])
        #expect(rects.map(\.isViewed) == [false, true])
    }
}
