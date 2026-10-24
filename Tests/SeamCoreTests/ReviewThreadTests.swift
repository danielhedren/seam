import Foundation
import TestSupport
import Testing

@testable import SeamCore

private let anchor = ThreadAnchor(
    path: "src/a.cs", side: .new, lines: 2...3, text: ["b", "c"])
private let start = Date(timeIntervalSince1970: 1_767_225_600)

private func ids() -> () -> String {
    var next = 0
    return {
        next += 1
        return String(format: "%08x", next)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ThreadRulesTests {
    @Test func aReplyAddsToTheThreadAndReopensIt() throws {
        var threads: [ReviewThread] = []
        let newID = ids()
        let thread = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: ReviewThread.reader,
            body: "  Why?  ", now: start, newID: newID)
        try ThreadRules.setResolved(true, &threads, id: thread.id, now: start)
        try ThreadRules.reply(
            &threads, to: thread.id, author: "claude", body: "Because.", now: start,
            newID: newID)

        #expect(threads.count == 1)
        #expect(threads[0].comments.map(\.body) == ["Why?", "Because."])
        #expect(threads[0].comments.map(\.author) == ["you", "claude"])
        #expect(!threads[0].isResolved)
    }

    @Test func anyoneResolvesOrReopensAnyThread() throws {
        var threads: [ReviewThread] = []
        let mine = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: ReviewThread.reader, body: "x",
            now: start)
        let agents = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "claude", body: "y", now: start)

        try ThreadRules.setResolved(true, &threads, id: mine.id, now: start)
        try ThreadRules.setResolved(true, &threads, id: agents.id, now: start)
        try ThreadRules.setResolved(false, &threads, id: agents.id, now: start)
        #expect(threads.map(\.isResolved) == [true, false])
    }

    @Test func emptyCommentsAndUnknownThreadsAreRefused() throws {
        var threads: [ReviewThread] = []
        #expect(throws: ThreadError.emptyComment) {
            try ThreadRules.open(
                &threads, worktree: "/w", anchor: anchor, author: "you", body: " \n ", now: start)
        }
        #expect(throws: ThreadError.unknownThread("nope")) {
            try ThreadRules.reply(&threads, to: "nope", author: "you", body: "x", now: start)
        }
    }

    @Test func anyThreadCanBeDeletedAndPutBackWhereItWas() throws {
        var threads: [ReviewThread] = []
        let next = ids()
        let first = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "claude", body: "One", now: start,
            newID: next)
        let second = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "you", body: "Two", now: start,
            newID: next)

        let deleted = try ThreadRules.delete(&threads, id: first.id)
        #expect(deleted.index == 0)
        #expect(threads.map(\.id) == [second.id])
        #expect(throws: ThreadError.unknownThread(first.id)) {
            try ThreadRules.delete(&threads, id: first.id)
        }

        ThreadRules.restore(deleted.thread, at: deleted.index, in: &threads)
        ThreadRules.restore(deleted.thread, at: deleted.index, in: &threads)
        #expect(threads.map(\.id) == [first.id, second.id])
        try ThreadRules.delete(&threads, id: second.id)
        #expect(threads.map(\.id) == [first.id])
    }

    @Test func idsStayUniqueWithinTheFile() throws {
        var threads: [ReviewThread] = []
        var sequence = ["aaaaaaaa", "c1", "aaaaaaaa", "bbbbbbbb", "c2"].makeIterator()
        let newID = { sequence.next() ?? "zzzzzzzz" }
        _ = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "you", body: "1", now: start,
            newID: newID)
        _ = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "you", body: "2", now: start,
            newID: newID)
        #expect(threads.map(\.id) == ["aaaaaaaa", "bbbbbbbb"])
    }
}

@Suite(.timeLimit(.minutes(1))) struct ThreadAnchorTests {
    @Test func linesThatMovedAreFoundNearestTheirOldPlace() {
        #expect(anchor.locate(in: ["a", "b", "c", "d"]) == 2...3)
        #expect(anchor.locate(in: ["new", "new", "a", "b", "c"]) == 4...5)
        #expect(anchor.locate(in: ["b", "c", "x", "x", "x", "x", "x", "b", "c"]) == 1...2)
    }

    @Test func linesThatAreGoneLeaveTheThreadOutdated() {
        #expect(anchor.locate(in: ["a", "b", "changed", "d"]) == nil)
        #expect(anchor.locate(in: ["b"]) == nil)
    }

    @Test func anAnchorTakesItsTextFromTheFile() {
        let file: [Substring] = ["a", "b", "c"]
        #expect(ThreadAnchor(path: "f", side: .new, lines: 2...3, in: file)?.text == ["b", "c"])
        #expect(ThreadAnchor(path: "f", side: .new, lines: 3...4, in: file) == nil)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ThreadStoreTests {
    private let repository = Repository(
        commonDirectory: URL(fileURLWithPath: "/r/app/.git"), anchor: URL(fileURLWithPath: "/r/app")
    )

    /// `seam wait` compares against these times, so they keep their fractions of a second;
    /// files written with whole seconds still read.
    @Test func timesKeepTheirMillisecondsAndWholeSecondFilesStillRead() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let at = start + 0.25
        try store.update(repository) { threads throws(ThreadError) in
            _ = try ThreadRules.open(
                &threads, worktree: "/r/app", anchor: anchor, author: "you", body: "Why?",
                now: at)
        }
        #expect(try store.threads(for: repository).first?.updated == at)

        let old = """
            {"version":1,"threads":[{"id":"1","worktree":"/r/app","author":"you",
            "anchor":{"path":"a","side":"new","lines":[1,1],"text":["x"]},"isResolved":false,
            "comments":[{"id":"c","author":"you","body":"b","date":"2026-01-01T00:00:00Z"}],
            "updated":"2026-01-01T00:00:00Z"}]}
            """
        try Data(old.utf8).write(to: store.file(for: repository))
        #expect(try store.threads(for: repository).first?.updated == start)
    }

    @Test func threadsRoundTripAndEachRepoHasItsOwnFile() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        try store.update(repository) { threads throws(ThreadError) in
            _ = try ThreadRules.open(
                &threads, worktree: "/r/app", anchor: anchor, author: "you", body: "Why?",
                now: start)
        }
        let other = Repository(
            commonDirectory: URL(fileURLWithPath: "/s/app/.git"),
            anchor: URL(fileURLWithPath: "/s/app"))

        #expect(try store.threads(for: repository).map(\.comments.first?.body) == ["Why?"])
        #expect(try store.threads(for: other).isEmpty)
        #expect(store.file(for: repository).lastPathComponent.hasPrefix("app-"))
        #expect(store.file(for: repository) != store.file(for: other))
    }

    @Test func concurrentWritersDontLoseEachOthersChanges() async throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let repository = repository
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    try? store.update(repository) { threads throws(ThreadError) in
                        _ = try ThreadRules.open(
                            &threads, worktree: "/r/app", anchor: anchor, author: "you",
                            body: "\(index)", now: start)
                    }
                }
            }
        }
        #expect(try store.threads(for: repository).count == 40)
    }

    @Test func aNewerFormatIsRefusedAndLeftAlone() throws {
        let directory = try TemporaryDirectory()
        let store = ThreadStore(directory: directory.url)
        let file = store.file(for: repository)
        let newer = Data(#"{"version": 99, "threads": []}"#.utf8)
        try newer.write(to: file)

        #expect(throws: ThreadError.unsupportedVersion(99)) {
            try store.update(repository) { _ throws(ThreadError) in }
        }
        #expect(try Data(contentsOf: file) == newer)
    }

    @Test func aStoreThatCantBeWrittenSaysSoRatherThanUnreadable() throws {
        let directory = try TemporaryDirectory()
        // A file where the store's folder should be, so creating the folder fails.
        let blocked = directory.url.appending(path: "threads")
        try Data().write(to: blocked)
        let store = ThreadStore(directory: blocked)

        let error = #expect(throws: ThreadError.self) {
            try store.update(repository) { _ throws(ThreadError) in }
        }
        guard case .unwritable = error else {
            Issue.record("expected .unwritable, got \(String(describing: error))")
            return
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ThreadTextTests {
    @Test func aThreadReadsAsItsLocationLinesAndComments() throws {
        var threads: [ReviewThread] = []
        let thread = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "you",
            body: "Why two?\nIt was one.", now: start, newID: ids())
        try ThreadRules.reply(
            &threads, to: thread.id, author: "claude", body: "Fixed.",
            now: start.addingTimeInterval(600), newID: ids())

        #expect(
            ThreadText.format(threads[0], timeZone: .gmt) == """
                #00000001  open  src/a.cs:2-3  opened by you
                    2 │ b
                    3 │ c
                  you · 2026-01-01T00:00:00Z
                    Why two?
                    It was one.
                  claude · 2026-01-01T00:10:00Z
                    Fixed.
                """)
    }

    /// Line numbers are from when the comment was written; the agent is told where they are
    /// now, or that they're gone, and what the old side means.
    @Test func whereAThreadIsNowIsSaidUnderItsHeader() throws {
        var threads: [ReviewThread] = []
        _ = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "you", body: "Why?", now: start,
            newID: ids())
        func second(_ placement: ThreadPlacement?) -> String? {
            ThreadText.format(threads[0], placement: placement, timeZone: .gmt)
                .split(separator: "\n").dropFirst().first.map(String.init)
        }
        #expect(second(.lines(9...10)) == "  Now at src/a.cs:9-10: the lines moved since.")
        #expect(second(.lines(2...3)) == "    2 │ b", "still where it was: nothing to say")
        #expect(
            second(.outdated)
                == "  Outdated: these lines aren't in src/a.cs any more, so it may be addressed.")
        #expect(second(.notShown) == "  src/a.cs isn't in this worktree any more.")

        var old = threads[0]
        old.anchor.side = .old
        #expect(
            ThreadText.format(old, timeZone: .gmt).split(separator: "\n").dropFirst().first
                == "  Old side: lines from the base that the change removed.")
    }

    @Test(arguments: [
        ("src/a.cs:12", "src/a.cs", 12...12), ("src/a.cs:12-14", "src/a.cs", 12...14),
        ("C:/odd:name.cs:3", "C:/odd:name.cs", 3...3),
    ])
    func locationsParse(argument: String, path: String, lines: ClosedRange<Int>) throws {
        let location = try #require(ThreadText.location(argument))
        #expect(location.path == path && location.lines == lines)
    }

    @Test(arguments: ["src/a.cs", "src/a.cs:", "src/a.cs:0", "src/a.cs:5-3", ":3", "a:x"])
    func badLocationsAreRefused(argument: String) {
        #expect(ThreadText.location(argument) == nil)
    }

    @Test func aRepoWideListingNamesEachThreadsWorktree() throws {
        var threads: [ReviewThread] = []
        _ = try ThreadRules.open(
            &threads, worktree: "/w/feature", anchor: anchor, author: "you", body: "Why?",
            now: start, newID: ids())
        let header = ThreadText.format(threads[0], showsWorktree: true, timeZone: .gmt)
            .split(separator: "\n").first
        #expect(header?.hasSuffix("opened by you  in /w/feature") == true)
        #expect(ThreadText.format(threads[0], timeZone: .gmt).contains("/w/feature") == false)
    }
}
