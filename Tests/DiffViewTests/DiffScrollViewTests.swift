import AppKit
import GitKit
import SeamCore
import Testing

@testable import DiffView

@MainActor @Suite struct DiffScrollViewTests {
    private func review(_ words: [String]) -> ReviewDiff {
        var hunk = Hunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: words.count, section: "")
        hunk.lines = words.enumerated().map { offset, word in
            DiffLine(kind: .added, text: word, oldNumber: nil, newNumber: offset + 1)
        }
        var file = FileDiff(oldPath: nil, newPath: "a.txt", status: .added)
        file.hunks = [hunk]
        return ReviewDiff(scope: .all, files: [ReviewFile(diff: file)])
    }

    @Test func findReportsMatchesMovesThroughThemAndKeepsThemAcrossAReload() {
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        var results: [String] = []
        view.onSearchResult = { current, total in results.append("\(current ?? 0)/\(total)") }
        view.show(DiffContent(review: review(["alpha", "beta", "alpha"])), position: .top)

        view.search("ALPHA")
        view.moveToMatch(by: 1)
        view.moveToMatch(by: 1)
        view.show(
            DiffContent(review: review(["alpha", "alpha", "beta", "alpha"])), position: .keep)
        view.search("gamma")

        #expect(results == ["1/2", "2/2", "1/2", "1/3", "0/0"])
    }
}
