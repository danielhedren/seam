import Foundation
import GitKit
import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct ReviewSearchTests {
    private func file(_ path: String, _ lines: [DiffLine]) -> ReviewFile {
        var diff = FileDiff(oldPath: path, newPath: path, status: .modified)
        var hunk = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 0, section: "")
        hunk.lines = lines
        diff.hunks = [hunk]
        return ReviewFile(diff: diff)
    }

    private let diff = ReviewDiff(
        scope: .all,
        files: [
            ReviewFile(diff: FileDiff(oldPath: "Delivery.png", newPath: nil, status: .deleted)),
            ReviewFile(
                diff: {
                    var diff = FileDiff(oldPath: "a.swift", newPath: "a.swift", status: .modified)
                    var hunk = Hunk(
                        oldStart: 10, oldCount: 3, newStart: 10, newCount: 3, section: "")
                    hunk.lines = [
                        DiffLine(
                            kind: .context, text: "    let delivery = 1", oldNumber: 10,
                            newNumber: 10),
                        DiffLine(
                            kind: .removed, text: "old(Delivery)", oldNumber: 11, newNumber: nil),
                        DiffLine(
                            kind: .added, text: "new(delivery, delivery)", oldNumber: nil,
                            newNumber: 11),
                        DiffLine(kind: .context, text: "done", oldNumber: 12, newNumber: 12),
                    ]
                    diff.hunks = [hunk]
                    return diff
                }()),
        ])

    @Test func pathsAndEveryKindOfHunkLineAreSearchedIgnoringCase() throws {
        let result = ReviewSearch.search(try #require(TextQuery("delivery").matcher()), in: diff)

        #expect(result.files.map(\.index) == [0, 1])
        #expect(result.files[0].pathRanges == [0..<8])
        #expect(result.files[0].lines.isEmpty)
        let lines = result.files[1].lines
        #expect(lines.map(\.kind) == [.context, .removed, .added])
        #expect(lines.map(\.number) == [10, 11, 11], "removed lines number on the old side")
        #expect(lines[2].ranges == [4..<12, 14..<22])
        #expect(result.matchCount == 4)
        #expect(!result.isTruncated)
    }

    @Test func matchCaseAndRegularExpressionsNarrowWhatMatches() throws {
        let cased = try #require(TextQuery("Delivery", matchesCase: true).matcher())
        #expect(ReviewSearch.search(cased, in: diff).files.map(\.index) == [0, 1])
        #expect(ReviewSearch.search(cased, in: diff).files[1].lines.map(\.number) == [11])

        let regex = try #require(TextQuery(#"new\(\w+"#, isRegex: true).matcher())
        #expect(ReviewSearch.search(regex, in: diff).files[0].lines[0].ranges == [0..<12])
        #expect(TextQuery("(", isRegex: true).matcher() == nil, "a pattern that doesn't compile")
        #expect(TextQuery("").matcher() == nil)
    }

    @Test func rangesCountCharactersNotBytes() throws {
        let matcher = try #require(TextQuery("cafe").matcher())
        #expect(matcher.ranges(in: "→ café") == [2..<6], "and diacritics are ignored")
        let regex = try #require(TextQuery("x*", isRegex: true).matcher())
        #expect(regex.ranges(in: "ab") == [], "empty matches are dropped")
    }

    @Test func listingStopsAtTheLimitAndSaysSo() throws {
        let lines = (1...3).map {
            DiffLine(kind: .added, text: "hit", oldNumber: nil, newNumber: $0)
        }
        let diff = ReviewDiff(scope: .all, files: [file("a", lines), file("b", lines)])
        let matcher = try #require(TextQuery("hit").matcher())

        let cut = ReviewSearch.search(matcher, in: diff, limit: 4)
        #expect(cut.files.map { $0.lines.count } == [3, 1])
        #expect(cut.isTruncated)
        #expect(!ReviewSearch.search(matcher, in: diff, limit: 6).isTruncated)
    }
}
