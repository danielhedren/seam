import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

private let repo = GitHubRepo(host: "github.com", owner: "owner", name: "app")
private let start = Date(timeIntervalSince1970: 1_767_225_600)

/// Lines 10–13 on both sides, with one removed and one added line.
private let hunk = """
    @@ -10,4 +10,4 @@ func count()
     let a = 1
    -let b = 2
    +let b = 3
     let c = 4
    """

private func gitHubThread(
    _ id: String = "PRRT_1", path: String = "a.swift", side: GitHubReviewThread.Side = .right,
    lines: ClosedRange<Int>? = 11...12, resolved: Bool = false, comments: [Int] = [7, 8]
) -> GitHubReviewThread {
    GitHubReviewThread(
        id: id, path: path, isResolved: resolved, side: side, lines: lines,
        comments: comments.enumerated().map { offset, number in
            .init(
                id: number, author: offset == 0 ? "octocat" : "hubot", body: "Comment \(number)",
                created: start.addingTimeInterval(Double(offset) * 60),
                url: "https://github.com/owner/app/pull/12#discussion_r\(number)",
                diffHunk: hunk)
        })
}

@Suite struct GitHubThreadTests {
    @Test func aHunksLinesAreReadOnTheSideTheCommentIsOn() {
        #expect(GitHubThreads.lines(11...12, side: .new, in: hunk) == ["let b = 3", "let c = 4"])
        #expect(GitHubThreads.lines(11...11, side: .old, in: hunk) == ["let b = 2"])
        #expect(GitHubThreads.lines(10...10, side: .old, in: hunk) == ["let a = 1"])
        #expect(GitHubThreads.lines(12...14, side: .new, in: hunk) == nil, "past the hunk")
        #expect(GitHubThreads.lines(1...1, side: .new, in: "not a hunk") == nil)
    }

    @Test func aPullRequestsThreadBecomesAReadOnlySeamThreadOnItsLines() throws {
        let threads = GitHubThreads.threads(
            from: [gitHubThread()], worktree: "/w", repo: repo, pullRequest: 12)
        let thread = try #require(threads.first)
        #expect(thread.id == "gh-7")
        #expect(
            thread.anchor
                == ThreadAnchor(
                    path: "a.swift", side: .new, lines: 11...12, text: ["let b = 3", "let c = 4"]))
        #expect(thread.author == "octocat")
        #expect(thread.comments.map(\.githubID) == [7, 8])
        #expect(thread.comments.map(\.author) == ["octocat", "hubot"])
        #expect(thread.updated == start.addingTimeInterval(60))
        #expect(
            thread.github
                == GitHubThreadSource(
                    repo: repo, pullRequest: 12, threadID: "PRRT_1",
                    url: "https://github.com/owner/app/pull/12#discussion_r7"))
        #expect(
            thread.gitHubReply
                == "gh api --hostname github.com -X POST repos/owner/app/pulls/12/comments/7/replies -f body='…'"
        )
    }

    @Test func aFileCommentAndAnEmptyThreadAreKeptApart() {
        let threads = GitHubThreads.threads(
            from: [gitHubThread(lines: nil), gitHubThread("PRRT_2", comments: [])], worktree: "/w",
            repo: repo, pullRequest: 12)
        #expect(threads.count == 1, "a thread without comments has nothing to show")
        #expect(threads.first?.github?.onFile == true)
        #expect(threads.first?.anchor.text == [])
    }

    /// `seam wait --since` sees a thread resolved on GitHub once, though no comment changed.
    @Test func aChangedThreadIsStampedWithTheReadAndAnUnchangedOneKeepsItsTime() {
        let read = GitHubThreads.threads(
            from: [gitHubThread(), gitHubThread("PRRT_2", comments: [9])], worktree: "/w",
            repo: repo, pullRequest: 12)
        var again = read
        again[0].isResolved = true
        let later = start.addingTimeInterval(3600)
        let stamped = GitHubThreads.stamped(again, previous: read, now: later)
        #expect(stamped[0].updated == later)
        #expect(stamped[1].updated == read[1].updated)
    }

    @Test func eachWorktreesReadReplacesOnlyItsOwnThreadsBesideTheSeamFile() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/app/.git"),
            anchor: URL(fileURLWithPath: "/r/app"))
        let a = GitHubThreads.threads(
            from: [gitHubThread()], worktree: "/a", repo: repo, pullRequest: 12)
        let b = GitHubThreads.threads(
            from: [gitHubThread("PRRT_9", comments: [90])], worktree: "/b", repo: repo,
            pullRequest: 13)
        try store.saveGitHubThreads(a, worktree: "/a", read: start, for: repository)
        try store.saveGitHubThreads(b, worktree: "/b", read: start, for: repository)
        let later = start.addingTimeInterval(60)
        try store.saveGitHubThreads([], worktree: "/a", read: later, for: repository)

        let saved = try store.gitHubThreads(for: repository)
        #expect(saved.threads.map(\.id) == ["gh-90"])
        #expect(saved.read == ["/a": later, "/b": start])
        #expect(try store.threads(for: repository).isEmpty, "Seam's own file is untouched")
        #expect(store.gitHubFile(for: repository).lastPathComponent.hasSuffix(".github.json"))
    }

    @Test func seamThreadsSaysWhereAGitHubThreadCameFromAndHowToAnswerIt() throws {
        let thread = try #require(
            GitHubThreads.threads(
                from: [gitHubThread()], worktree: "/w", repo: repo, pullRequest: 12
            ).first)
        let text = ThreadText.format(thread, read: start, timeZone: .gmt)
        #expect(
            text == """
                #gh-7  open  a.swift:11-12  opened by octocat on GitHub pull request #12
                  Read from github.com/owner/app at 2026-01-01 00:00. Seam can't answer it; reply on GitHub with:
                    gh api --hostname github.com -X POST repos/owner/app/pulls/12/comments/7/replies -f body='…'
                  GitHub thread PRRT_1 · https://github.com/owner/app/pull/12#discussion_r7
                    11 │ let b = 3
                    12 │ let c = 4
                  octocat · 2026-01-01 00:00 · GitHub comment 7
                    Comment 7
                  hubot · 2026-01-01 00:01 · GitHub comment 8
                    Comment 8
                """)
    }
}
