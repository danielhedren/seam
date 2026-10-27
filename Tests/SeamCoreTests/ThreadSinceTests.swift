import GitKit
import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct ThreadSinceTests {
    private let anchor = ThreadAnchor(
        path: "a.swift", side: .new, lines: 3...3, text: ["let total = 1"])

    /// An outdated thread shows what became of its lines, and its card goes after what replaced
    /// them, moved down by the lines added above.
    @Test func anOutdatedThreadShowsTheChangeToItsLinesAndWhereTheyAreNow() throws {
        let then =
            "import A\n\nlet total = 1\nprint(total)\n" + String(repeating: "x\n", count: 20)
            + "let tail = 0\n"
        let now =
            "import A\nimport B\nimport C\n\nlet total = 2\nprint(total)\n"
            + String(repeating: "x\n", count: 20) + "let tail = 1\n"
        let since = try #require(ThreadSince.change(of: anchor, from: then, to: now))
        #expect(since.line == 5, "after its replacement, now line 5")
        // Only the hunk around the thread's lines; the tail's change is elsewhere.
        #expect(since.hunks.count == 1)
        let lines = since.hunks[0].lines.map { "\($0.kind) \($0.text)" }
        #expect(lines.contains("removed let total = 1"))
        #expect(lines.contains("added let total = 2"))
        #expect(!lines.contains("added let tail = 1"))
    }

    /// A text without the thread's lines where it says they were isn't what it was written on.
    @Test func aTextWithoutTheThreadsLinesIsNotItsOrigin() {
        #expect(ThreadSince.change(of: anchor, from: "a\nb\nc\n", to: "a\n") == nil)
        #expect(ThreadSince.change(of: anchor, from: "a\n", to: "a\n") == nil)
        #expect(
            ThreadSince.change(of: anchor, from: "a\nb\nlet total = 1\r\n", to: "a\n") != nil,
            "line endings don't count")
    }

    /// However much changed nearby, a one-line thread gets a few lines: its line and two
    /// either side as they were, and as many around where it is now.
    @Test func theChangeShownIsOnlyWhatIsAboutTheThreadsLines() throws {
        let then = (1...40).map { "old \($0)" }.joined(separator: "\n") + "\n"
        let now =
            (1...40).map { $0 == 20 ? "new 20" : "old \($0)" }.joined(separator: "\n") + "\n"
            + (1...30).map { "added \($0)" }.joined(separator: "\n") + "\n"
        let anchor = ThreadAnchor(path: "a", side: .new, lines: 20...20, text: ["old 20"])
        let since = try #require(ThreadSince.change(of: anchor, from: then, to: now))
        #expect(since.line == 20)
        #expect(
            since.hunks.flatMap(\.lines).map(\.text)
                == ["old 18", "old 19", "old 20", "new 20", "old 21", "old 22"])
    }
}
