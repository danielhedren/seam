import Foundation
import GitKit
import Testing

@testable import SeamCore

/// SPEC §7.7, §7.9: where a thread is now, as the app and `seam` both work it out.
@Suite(.timeLimit(.minutes(1))) struct ThreadPlacerTests {
    private func thread(
        _ id: String, _ path: String = "a.txt", side: ThreadAnchor.Side = .new,
        lines: ClosedRange<Int> = 2...2, text: [String] = ["two"], resolved: Bool = false
    ) -> ReviewThread {
        ReviewThread(
            id: id, worktree: "/w",
            anchor: ThreadAnchor(path: path, side: side, lines: lines, text: text), author: "you",
            isResolved: resolved,
            comments: [ThreadComment(id: "c\(id)", author: "you", body: "Why?", date: .now)])
    }

    private let files: [String: (old: String, new: String)] = [
        "a.txt": (old: "one\ntwo\n", new: "zero\none\ntwo\n"),
        "b.txt": (old: "gone\n", new: "here\n"),
    ]

    private func context(commits: [String] = [], newest: String? = nil) -> ThreadPlacer.Context {
        let files = files
        return ThreadPlacer.Context(
            paths: Set(files.keys),
            text: { path, side in
                (side == .new ? files[path]?.new : files[path]?.old).map(TextLines.split)
            },
            commits: commits, newestShown: newest)
    }

    @Test func aThreadFollowsItsLinesAndGoesOutdatedWhenTheyreGone() {
        let placed = ThreadPlacer.place(
            [
                thread("moved"), thread("old", "b.txt", side: .old, lines: 1...1, text: ["gone"]),
                thread("gone", "b.txt", lines: 1...1, text: ["gone"]),
                thread("elsewhere", "c.txt"),
            ], in: context())
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.placement) })
        #expect(byID["moved"] == .lines(3...3))
        #expect(byID["old"] == .lines(1...1))
        #expect(byID["gone"] == .outdated)
        #expect(byID["elsewhere"] == .notShown)
    }

    @Test func openThreadsComeFirstThenByFileAndLine() {
        let placed = ThreadPlacer.place(
            [
                thread("3", "b.txt", lines: 1...1, text: ["here"]),
                thread("1", resolved: true), thread("2", lines: 1...1, text: ["zero"]),
            ], in: context())
        #expect(placed.map(\.id) == ["2", "3", "1"])
    }

    @Test func aPullRequestThreadFromALaterCommitOrWithoutTextIsntOutdated() {
        let repo = GitHubRepo(host: "github.com", owner: "o", name: "a")
        var later = thread("later", lines: 1...1, text: ["not yet"])
        later.github = GitHubThreadSource(
            repo: repo, pullRequest: 1, threadID: "T", url: "u", commit: "c2")
        var blind = thread("blind", lines: 9...9, text: [])
        blind.github = GitHubThreadSource(repo: repo, pullRequest: 1, threadID: "U", url: "u")
        let placed = ThreadPlacer.place(
            [later, blind], in: context(commits: ["c2", "c1"], newest: "c1"))
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.placement) })
        #expect(byID["later"] == .later)
        #expect(byID["blind"] == .notShown)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ReviewerIdentityTests {
    private func thread(_ authors: [String], resolved: Bool = false) -> ReviewThread {
        ReviewThread(
            id: "t", worktree: "/w",
            anchor: ThreadAnchor(path: "a", side: .new, lines: 1...1, text: ["x"]),
            author: authors.first ?? "", isResolved: resolved,
            comments: authors.enumerated().map { index, author in
                ThreadComment(id: "\(index)", author: author, body: "b", date: .now)
            })
    }

    /// The reader's turn comes when someone else spoke last on an open thread; their own older
    /// comments, signed "you", still count as theirs.
    @Test func anOpenThreadAwaitsTheReaderWhenSomeoneElseSpokeLast() {
        let me = ReviewerIdentity(name: "reader@example.com")
        #expect(me.awaitsReply(thread(["reader@example.com", "claude"])))
        #expect(me.awaitsReply(thread(["octocat"])))
        #expect(!me.awaitsReply(thread(["claude", "reader@example.com"])))
        #expect(!me.awaitsReply(thread(["claude", "you"])))
        #expect(!me.awaitsReply(thread(["reader@example.com", "claude"], resolved: true)))
    }
}
