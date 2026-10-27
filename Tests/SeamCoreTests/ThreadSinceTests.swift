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
}
