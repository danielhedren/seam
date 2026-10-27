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

@Suite(.timeLimit(.minutes(1))) struct GitHubThreadTests {
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
                == "gh api --hostname github.com -X POST repos/owner/app/pulls/12/comments/7/replies -F body=@reply.md"
        )
    }

    /// One place says what may be done with a thread: Seam's are Seam's to change, a pull
    /// request's are only read and opened, and jumped to when GitHub said its commit.
    @Test func seamsThreadsCanBeChangedAndAPullRequestsOnlyReadAndOpened() throws {
        let read = GitHubThreads.threads(
            from: [gitHubThread(), gitHubThread("PRRT_2", comments: [9])], worktree: "/w",
            repo: repo, pullRequest: 12)
        var withCommit = try #require(read.first)
        withCommit.github?.commit = "abc"
        #expect(withCommit.capabilities == [.openRemote, .jumpToCommit])
        #expect(read[1].capabilities == [.openRemote])
        #expect(read[1].source == .gitHub)

        var local = read[1]
        local.github = nil
        #expect(local.capabilities == [.reply, .resolve, .delete])
        #expect(local.source == .seam)
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

    /// A thread read for the first time is news to an agent waiting since before the read, however
    /// old its comments: the app may have been closed when they were written.
    @Test func aThreadReadForTheFirstTimeIsStampedWithTheRead() {
        let read = GitHubThreads.threads(
            from: [gitHubThread()], worktree: "/w", repo: repo, pullRequest: 12)
        let later = start.addingTimeInterval(3600)
        #expect(GitHubThreads.stamped(read, previous: [], now: later).first?.updated == later)
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

    /// The conversation is kept per worktree beside its threads, and goes with them.
    @Test func eachWorktreesConversationIsKeptBesideItsThreads() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/app/.git"),
            anchor: URL(fileURLWithPath: "/r/app"))
        let comment = GitHubConversationItem(
            id: 5, author: "octocat", body: "Looks close.", created: start, url: "c5")
        let conversation = PullRequestConversation(
            repo: repo, pullRequest: 12, items: [comment], viewer: "me")
        try store.saveGitHubThreads(
            [], conversation: conversation, worktree: "/a", read: start, for: repository)
        try store.saveGitHubThreads(
            [], conversation: PullRequestConversation(repo: repo, pullRequest: 13, items: []),
            worktree: "/b", read: start, for: repository)

        #expect(try store.gitHubThreads(for: repository).conversations["/a"] == conversation)
        try store.pruneGitHubThreads(keeping: ["/b"], for: repository)
        #expect(try store.gitHubThreads(for: repository).conversations.keys.sorted() == ["/b"])
        try store.saveGitHubThreads([], worktree: "/b", read: start, for: repository)
        #expect(try store.gitHubThreads(for: repository).conversations.isEmpty)
    }

    /// One refresh's reads go in one write: the worktrees named are replaced, an empty read
    /// clears one, and the rest stay.
    @Test func severalWorktreesReadsAreSavedTogether() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/app/.git"),
            anchor: URL(fileURLWithPath: "/r/app"))
        func threads(_ worktree: String, _ id: Int) -> [ReviewThread] {
            GitHubThreads.threads(
                from: [gitHubThread("PRRT_\(id)", comments: [id])], worktree: worktree,
                repo: repo, pullRequest: 12)
        }
        try store.saveGitHubReads(
            [
                "/a": GitHubRead(threads: threads("/a", 1)),
                "/b": GitHubRead(threads: threads("/b", 2)),
                "/c": GitHubRead(threads: threads("/c", 3)),
            ], read: start, for: repository)
        let later = start.addingTimeInterval(60)
        let stored = try store.saveGitHubReads(
            ["/a": GitHubRead(threads: threads("/a", 4)), "/b": GitHubRead(threads: [])],
            read: later, for: repository)

        #expect(Set(stored.map(\.id)) == ["gh-3", "gh-4"])
        let saved = try store.gitHubThreads(for: repository)
        #expect(saved.read == ["/a": later, "/b": later, "/c": start])
    }

    /// What `seam` reads: Seam's threads with GitHub's, which it refuses to change and places
    /// by the worktree's file.
    @Test func aListingHoldsBothKindsAndRefusesGitHubsWithItsCommand() throws {
        let directory = try TemporaryDirectory()
        let worktree = try TemporaryDirectory()
        try Data("one\ntwo\n".utf8).write(to: worktree.url.appending(path: "a.swift"))
        let store = ThreadStore(directory: directory.url)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/app/.git"),
            anchor: URL(fileURLWithPath: "/r/app"))
        try store.saveGitHubThreads(
            GitHubThreads.threads(
                from: [gitHubThread()], worktree: worktree.url.path, repo: repo, pullRequest: 12),
            worktree: worktree.url.path, read: start, for: repository)

        let listing = try ThreadListing(store: store, repository: repository)
        let thread = try #require(listing.thread("gh-7"))
        #expect(listing.read[worktree.url.path] == start)
        #expect(listing.refusal(for: "gh-7")?.hasSuffix("-F body=@reply.md") == true)
        #expect(listing.refusal(for: "nope") == nil)
        #expect(ThreadListing.placement(of: thread) == .outdated)
    }

    /// A file written before conversations were kept still reads.
    @Test func aGitHubFileWithoutConversationsReads() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/app/.git"),
            anchor: URL(fileURLWithPath: "/r/app"))
        try Data(#"{"version":1,"threads":[],"read":{"/a":"2026-10-23T12:00:00.000Z"}}"#.utf8)
            .write(to: store.gitHubFile(for: repository))

        let saved = try store.gitHubThreads(for: repository)
        #expect(saved.read.keys.sorted() == ["/a"])
        #expect(saved.conversations.isEmpty)
    }

    /// What the app read an hour ago may have changed on GitHub; the agent is told.
    @Test func aPullRequestReadLongAgoIsFlaggedAsPossiblyStale() throws {
        let thread = try #require(
            GitHubThreads.threads(
                from: [gitHubThread()], worktree: "/w", repo: repo, pullRequest: 12
            ).first)
        let fresh = ThreadText.format(thread, read: start, now: start + 60, timeZone: .gmt)
        let stale = ThreadText.format(thread, read: start, now: start + 3600, timeZone: .gmt)
        #expect(!fresh.contains("may be out of date"))
        #expect(stale.contains("This may be out of date: Seam reads the pull request again"))
    }

    @Test func seamThreadsSaysWhereAGitHubThreadCameFromAndHowToAnswerIt() throws {
        let thread = try #require(
            GitHubThreads.threads(
                from: [gitHubThread()], worktree: "/w", repo: repo, pullRequest: 12
            ).first)
        let text = ThreadText.format(thread, read: start, now: start, timeZone: .gmt)
        #expect(
            text == """
                #gh-7  open  a.swift:11-12  opened by octocat on GitHub pull request #12
                  Read from github.com/owner/app at 2026-01-01T00:00:00Z. Seam can't answer it; write your reply to reply.md, then run:
                    gh api --hostname github.com -X POST repos/owner/app/pulls/12/comments/7/replies -F body=@reply.md
                  GitHub thread PRRT_1 · https://github.com/owner/app/pull/12#discussion_r7
                    11 │ let b = 3
                    12 │ let c = 4
                  octocat · 2026-01-01T00:00:00Z · GitHub comment 7
                    Comment 7
                  hubot · 2026-01-01T00:01:00Z · GitHub comment 8
                    Comment 8
                """)
    }
}
