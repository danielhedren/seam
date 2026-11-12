import SeamCore
import Testing

@Suite(.timeLimit(.minutes(1))) struct JumpHistoryTests {
    private func place(_ path: String, _ line: Int) -> ScrollAnchor {
        ScrollAnchor(path: path, line: line, offset: 0)
    }

    @Test func backReturnsToWhereEachJumpStartedAndForwardRetracesIt() {
        var history = JumpHistory()
        history.record(place("a.swift", 1))
        history.record(place("b.swift", 20))
        let everything: (String) -> Bool = { _ in true }

        #expect(history.goBack(from: place("c.swift", 3), has: everything) == place("b.swift", 20))
        #expect(history.goBack(from: place("b.swift", 20), has: everything) == place("a.swift", 1))
        #expect(history.goBack(from: place("a.swift", 1), has: everything) == nil)
        #expect(
            history.goForward(from: place("a.swift", 1), has: everything) == place("b.swift", 20))
        #expect(
            history.goForward(from: place("b.swift", 20), has: everything) == place("c.swift", 3))
        #expect(!history.canGoForward(has: everything))
    }

    @Test func aPlaceInAFileTheDiffNoLongerHasIsSkipped() {
        var history = JumpHistory()
        history.record(place("kept.swift", 4))
        history.record(place("gone.swift", 9))
        let has: (String) -> Bool = { $0 != "gone.swift" }

        #expect(history.canGoBack(has: has))
        #expect(history.goBack(from: place("now.swift", 1), has: has) == place("kept.swift", 4))
        #expect(!history.canGoBack(has: has))
    }

    @Test func aNewJumpDropsWhatForwardWouldHaveGoneTo() {
        var history = JumpHistory()
        history.record(place("a.swift", 1))
        _ = history.goBack(from: place("b.swift", 2), has: { _ in true })
        history.record(place("a.swift", 1))

        #expect(history.forward == [])
        #expect(history.back == [place("a.swift", 1)])
    }
}
