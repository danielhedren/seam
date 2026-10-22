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

@Suite struct ThreadRulesTests {
    @Test func aReplyAddsToTheThreadAndReopensIt() throws {
        var threads: [ReviewThread] = []
        let newID = ids()
        let thread = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: ReviewThread.reader,
            body: "  Why?  ", now: start, newID: newID)
        try ThreadRules.setResolved(true, &threads, id: thread.id, by: ReviewThread.reader)
        try ThreadRules.reply(
            &threads, to: thread.id, author: "claude", body: "Because.", now: start,
            newID: newID)

        #expect(threads.count == 1)
        #expect(threads[0].comments.map(\.body) == ["Why?", "Because."])
        #expect(threads[0].comments.map(\.author) == ["you", "claude"])
        #expect(!threads[0].isResolved)
    }

    @Test func onlyTheOpenerResolvesOrReopens() throws {
        var threads: [ReviewThread] = []
        let mine = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: ReviewThread.reader, body: "x",
            now: start)
        let agents = try ThreadRules.open(
            &threads, worktree: "/w", anchor: anchor, author: "claude", body: "y", now: start)

        #expect(throws: ThreadError.notAuthor(thread: mine.id, author: "you")) {
            try ThreadRules.setResolved(true, &threads, id: mine.id, by: "claude")
        }
        try ThreadRules.setResolved(true, &threads, id: agents.id, by: "claude")
        #expect(throws: ThreadError.notAuthor(thread: agents.id, author: "claude")) {
            try ThreadRules.setResolved(false, &threads, id: agents.id, by: ReviewThread.reader)
        }
        #expect(threads.map(\.isResolved) == [false, true])
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

@Suite struct ThreadAnchorTests {
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

@Suite struct ThreadStoreTests {
    private let repository = Repository(
        commonDirectory: URL(fileURLWithPath: "/r/app/.git"), anchor: URL(fileURLWithPath: "/r/app")
    )

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
}

@Suite struct ThreadTextTests {
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
                  you · 2026-01-01 00:00
                    Why two?
                    It was one.
                  claude · 2026-01-01 00:10
                    Fixed.
                """)
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
}
