import Testing

@testable import Features
@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct QuotedLinesTests {
    @Test func aQuoteOfEightLinesShowsWhole() {
        #expect(QuotedLines.visible(1, showsAll: false) == (1, 0))
        #expect(QuotedLines.visible(8, showsAll: false) == (8, 0))
    }

    @Test func aLongerQuoteShowsSevenLinesAndARowCountingTheRest() {
        #expect(QuotedLines.visible(9, showsAll: false) == (7, 2))
        #expect(QuotedLines.visible(40, showsAll: false) == (7, 33))
    }

    @Test func anExpandedQuoteShowsEveryLine() {
        #expect(QuotedLines.visible(40, showsAll: true) == (40, 0))
    }
}
