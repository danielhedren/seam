import Foundation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WorktreeSwitcherTests {
    @Test func arrowsMoveTheHighlightAndStopAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(WorktreeSwitcher.moved("a", by: 1, in: ids) == "b")
        #expect(WorktreeSwitcher.moved("c", by: 1, in: ids) == "c")
        #expect(WorktreeSwitcher.moved("a", by: -1, in: ids) == "a")
        #expect(WorktreeSwitcher.moved("gone", by: 1, in: ids) == "b")
        #expect(WorktreeSwitcher.moved(nil, by: 1, in: []) == nil)
    }
}
