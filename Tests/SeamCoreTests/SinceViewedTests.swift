import GitKit
import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct SinceViewedTests {
    /// The hunks as git would print them.
    private func patch(_ old: String, _ new: String) -> [String] {
        SinceViewed.hunks(from: old, to: new).flatMap { hunk in
            ["@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"]
                + hunk.lines.map { line in
                    let mark =
                        switch line.kind {
                        case .context: " "
                        case .added: "+"
                        case .removed: "-"
                        }
                    return mark + line.text + (line.noNewlineAtEnd ? " ⏎̸" : "")
                }
        }
    }

    private func numbered(_ range: ClosedRange<Int>, replacing: [Int: String] = [:]) -> String {
        range.map { replacing[$0] ?? "\($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func aChangedLineShowsWithThreeLinesAroundIt() {
        #expect(
            patch(numbered(1...10), numbered(1...10, replacing: [5: "five"])) == [
                "@@ -2,7 +2,7 @@", " 2", " 3", " 4", "-5", "+five", " 6", " 7", " 8",
            ])
    }

    @Test func changesFarApartAreSeparateHunksAndNearOnesShareOne() {
        #expect(
            patch(numbered(1...20), numbered(1...20, replacing: [2: "two", 18: "eighteen"])) == [
                "@@ -1,5 +1,5 @@", " 1", "-2", "+two", " 3", " 4", " 5",
                "@@ -15,6 +15,6 @@", " 15", " 16", " 17", "-18", "+eighteen", " 19", " 20",
            ])
        #expect(
            patch(numbered(1...20), numbered(1...20, replacing: [5: "five", 11: "eleven"]))
                .count { $0.hasPrefix("@@") } == 1)
    }

    @Test func linesAddedAtTheEndAndAFirstVersionCountFromNothing() {
        #expect(
            patch("a\nb\n", "a\nb\nc") == ["@@ -1,2 +1,3 @@", " a", " b", "+c ⏎̸"])
        #expect(patch("", "a\n") == ["@@ -0,0 +1,1 @@", "+a"])
        #expect(patch("a\nb\n", "b\n") == ["@@ -1,2 +1,1 @@", "-a", " b"])
    }

    @Test func aDroppedFinalNewlineIsAChange() {
        #expect(patch("a\n", "a") == ["@@ -1,1 +1,1 @@", "-a", "+a ⏎̸"])
        #expect(patch("a\n", "a\n") == [])
    }

    @Test func theFileKeepsItsPathAndReadsAsModified() {
        var file = FileDiff(oldPath: nil, newPath: "a.txt", status: .added)
        file.newBlob = "222"
        let diff = SinceViewed.diff(file, from: "one\n", to: "two\n")
        #expect(diff.oldPath == "a.txt")
        #expect(diff.status == .modified)
        #expect(diff.newBlob == "222")
        #expect(diff.additions == 1 && diff.deletions == 1)
    }
}
