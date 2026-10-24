import Foundation
import Synchronization
import TestSupport
import Testing

@testable import SeamCore

private let start = Date(timeIntervalSince1970: 1_767_225_600)

private func thread(
    _ id: String, in worktree: String = "/a", resolved: Bool = false, updated: Date = start
) -> ReviewThread {
    ReviewThread(
        id: id, worktree: worktree,
        anchor: ThreadAnchor(path: "f", side: .new, lines: 1...1, text: ["x"]), author: "you",
        isResolved: resolved,
        comments: [ThreadComment(id: "c\(id)", author: "you", body: "Why?", date: start)],
        updated: updated)
}

@Suite(.timeLimit(.minutes(1))) struct ThreadScopeTests {
    @Test func aScopeIsOneWorktreeOrTheRepoAndSinceIncludesResolvedActivity() {
        let threads = [
            thread("1"), thread("2", in: "/b"), thread("3", resolved: true),
            thread("4", resolved: true, updated: start.addingTimeInterval(60)),
        ]
        func ids(_ scope: ThreadScope) -> [String] { threads.filter(scope.contains).map(\.id) }

        #expect(ids(ThreadScope(worktree: "/a")) == ["1"])
        #expect(ids(ThreadScope(worktree: nil)) == ["1", "2"])
        #expect(ids(ThreadScope(worktree: nil, includesResolved: true)) == ["1", "2", "3", "4"])
        #expect(ids(ThreadScope(worktree: "/a", since: start.addingTimeInterval(60))) == ["4"])
        // At the same second counts, so a change isn't lost between two waits.
        #expect(ids(ThreadScope(worktree: "/a", since: start)) == ["1", "3", "4"])
    }

    @Test func everyChangeMovesTheLastActivityAndOldFilesUseTheLatestComment() throws {
        var threads: [ReviewThread] = []
        let opened = try ThreadRules.open(
            &threads, worktree: "/a", anchor: thread("x").anchor, author: "you", body: "Why?",
            now: start)
        #expect(threads[0].lastActivity == start)
        try ThreadRules.reply(
            &threads, to: opened.id, author: "claude", body: "So.", now: start + 10)
        #expect(threads[0].lastActivity == start + 10)
        try ThreadRules.setResolved(true, &threads, id: opened.id, now: start + 20)
        #expect(threads[0].lastActivity == start + 20)

        var old = threads[0]
        old.updated = nil
        #expect(old.lastActivity == start + 10)
    }

    @Test func changesAreNewEditedAndDeletedThreadsInTheScope() {
        let before = [thread("1"), thread("2"), thread("3", in: "/b")]
        var edited = thread("2")
        edited.isResolved = true
        let after = [edited, thread("4"), thread("5", in: "/b")]

        let changes = ThreadChanges.between(before, after, worktree: "/a")
        #expect(changes.changed.map(\.id) == ["2", "4"])
        #expect(changes.deleted == ["1"])
        let repo = ThreadChanges.between(before, after, worktree: nil)
        #expect(repo.changed.map(\.id) == ["2", "4", "5"])
        #expect(repo.deleted == ["1", "3"])
    }
}

/// What the wait reads, changed by the test between events.
private final class Store: Sendable {
    let threads = Mutex([thread("1")])
}

@Suite(.timeLimit(.minutes(1))) struct ThreadWaitTests {
    private let store = Store()

    private func read() -> @Sendable () throws(ThreadError) -> [ReviewThread] {
        { [store] () throws(ThreadError) in store.threads.withLock { $0 } }
    }

    @Test func aChangeAfterTheWaitStartsEndsIt() async throws {
        let (events, sender) = AsyncStream.makeStream(of: [String].self)
        let clock = ManualClock()
        let waiting = Task { [read = read()] in
            try await ThreadWait.next(
                in: ThreadScope(worktree: "/a"), read: read, events: events, clock: clock,
                timeout: .seconds(60), now: { start + 0.7 })
        }
        await clock.sleepers()
        sender.yield(["unrelated"])
        store.threads.withLock { $0.append(thread("2", in: "/b")) }
        sender.yield(["other worktree"])
        store.threads.withLock { $0.append(thread("3")) }
        sender.yield(["threads.json"])

        let result = try #require(try await waiting.value)
        #expect(result.changes.changed.map(\.id) == ["3"])
        #expect(result.asOf == start + 0.7, "exact, so the next wait starts after this read")
    }

    /// An orchestrator loops `seam wait --since <As of>`: a change it was told about isn't
    /// reported again, even within the same second.
    @Test func theNextWaitFromAsOfDoesntRepeatWhatThisOneReported() async throws {
        let (events, sender) = AsyncStream.makeStream(of: [String].self)
        let clock = ManualClock()
        let waiting = Task { [read = read()] in
            try await ThreadWait.next(
                in: ThreadScope(worktree: "/a"), read: read, events: events, clock: clock,
                timeout: .seconds(60), now: { start + 0.4 })
        }
        await clock.sleepers()
        store.threads.withLock { $0.append(thread("2", updated: start + 0.3)) }
        sender.yield(["threads.json"])
        let asOf = try #require(try await waiting.value).asOf

        let (quiet, ended) = AsyncStream.makeStream(of: [String].self)
        ended.finish()
        let again = try await ThreadWait.next(
            in: ThreadScope(worktree: "/a", since: asOf), read: read(), events: quiet,
            clock: ManualClock(), timeout: nil, now: { start + 0.5 })
        #expect(again == nil)
    }

    @Test func nothingChangingUntilTheTimeoutReturnsNil() async throws {
        let (events, _) = AsyncStream.makeStream(of: [String].self)
        let clock = ManualClock()
        let waiting = Task { [read = read()] in
            try await ThreadWait.next(
                in: ThreadScope(worktree: "/a"), read: read, events: events, clock: clock,
                timeout: .seconds(60))
        }
        await clock.sleepers()
        clock.advance(by: .seconds(60))
        #expect(try await waiting.value == nil)
    }

    @Test func activitySinceTheLastAsOfComesBackAtOnce() async throws {
        let (events, _) = AsyncStream.makeStream(of: [String].self)
        let result = try await ThreadWait.next(
            in: ThreadScope(worktree: "/a", since: start), read: read(), events: events,
            clock: ManualClock(), timeout: nil)
        #expect(result?.changes.changed.map(\.id) == ["1"])
    }
}
