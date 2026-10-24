import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct IntraLineDiffTests {
    private func marked(_ line: String, _ ranges: [Range<Int>]) -> [String] {
        let characters = Array(line)
        return ranges.map { String(characters[$0]) }
    }

    @Test func aChangedWordIsTheOnlyHighlight() {
        let old = "    var total: Int"
        let new = "    var total: Decimal"
        let result = IntraLineDiff.highlights(removed: [old], added: [new])
        #expect(marked(old, result.removed[0]) == ["Int"])
        #expect(marked(new, result.added[0]) == ["Decimal"])
    }

    @Test func adjacentChangedTokensMergeIntoOneRange() {
        let old = "call(a, b)"
        let new = "call(x.y, b)"
        let result = IntraLineDiff.highlights(removed: [old], added: [new])
        #expect(marked(old, result.removed[0]) == ["a"])
        #expect(marked(new, result.added[0]) == ["x.y"])
    }

    @Test func linesArePairedBySimilarityNotPosition() {
        let removed = ["let name = user.name", "let age = user.age"]
        let added = ["let id = user.id", "let name = user.fullName", "let age = user.age + 1"]
        let result = IntraLineDiff.highlights(removed: removed, added: added)
        #expect(result.added[0].isEmpty)
        #expect(marked(added[1], result.added[1]) == ["fullName"])
        #expect(marked(added[2], result.added[2]) == [" + 1"])
        #expect(marked(removed[0], result.removed[0]) == ["name"])
    }

    @Test func unrelatedLinesGetNoHighlights() {
        let result = IntraLineDiff.highlights(
            removed: ["return cache[key]"], added: ["// TODO: remove this"])
        #expect(result == IntraLineDiff.Result(removed: [[]], added: [[]]))
    }

    @Test func offsetsCountCharactersNotBytes() {
        let old = "låt x = å"
        let new = "låt x = ö"
        let result = IntraLineDiff.highlights(removed: [old], added: [new])
        #expect(result.removed[0] == [8..<9])
        #expect(result.added[0] == [8..<9])
    }

    @Test func tooManyLinesFallBackToPositionalPairing() {
        let removed = (0..<30).map { "value \($0) old" }
        let added = (0..<30).map { "value \($0) new" }
        let result = IntraLineDiff.highlights(removed: removed, added: added)
        #expect(marked(added[29], result.added[29]) == ["new"])
    }
}
