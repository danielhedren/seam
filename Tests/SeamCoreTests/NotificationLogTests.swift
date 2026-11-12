import Foundation
import SeamCore
import Testing

/// The bell's log (SPEC §7.10): newest first, replaced by id, read state, and its cap.
@Suite(.timeLimit(.minutes(1))) struct NotificationLogTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, after seconds: TimeInterval = 0, posted: Bool = true)
        -> NotificationLog.Entry
    {
        NotificationLog.Entry(
            id: id, group: "/repo", title: "feature", body: "claude: Done",
            url: URL(string: "seam://open?path=/repo"), date: start.addingTimeInterval(seconds),
            wasPosted: posted)
    }

    private func log(_ ids: String...) -> NotificationLog {
        var log = NotificationLog()
        for (offset, id) in ids.enumerated() {
            log.record(entry(id, after: Double(offset)), now: start.addingTimeInterval(60))
        }
        return log
    }

    @Test func entriesAreNewestFirstAndUnreadUntilMarked() {
        let log = log("a", "b", "c")
        #expect(log.entries.map(\.id) == ["c", "b", "a"])
        #expect(log.unreadCount == 3)
        #expect(log.newestUnread?.id == "c")
    }

    @Test func newerNewsWithTheSameIdReplacesTheEntryAndIsUnreadAgain() {
        var log = log("a", "b")
        log.markRead(["a"])
        var newer = entry("a", after: 30)
        newer.body = "claude: Done again"

        log.record(newer, now: start.addingTimeInterval(60))

        #expect(log.entries.map(\.id) == ["a", "b"])
        #expect(log.entries.first?.body == "claude: Done again")
        #expect(log.entries.first?.isRead == false)
        #expect(log.unreadCount == 2)
    }

    @Test func markingReadReturnsOnlyWhatItMadeRead() {
        var log = log("a", "b", "c")

        #expect(log.markRead(["a", "c", "missing"]).map(\.id) == ["c", "a"])
        #expect(log.unreadCount == 1)
        #expect(log.newestUnread?.id == "b")
        #expect(log.markRead(["a"]).isEmpty)

        #expect(log.markAllRead().map(\.id) == ["b"])
        #expect(log.unreadCount == 0)
        #expect(log.newestUnread == nil)
        #expect(log.markAllRead().isEmpty)
    }

    @Test func theLogKeepsTheNewestTwoHundred() {
        var log = NotificationLog()
        for index in 0..<205 {
            log.record(
                entry("n\(index)", after: Double(index)), now: start.addingTimeInterval(300))
        }
        #expect(log.entries.count == 200)
        #expect(log.entries.first?.id == "n204")
        #expect(log.entries.last?.id == "n5")
    }

    @Test func entriesOlderThanThirtyDaysDropOut() {
        var log = log("old", "kept")
        let day: TimeInterval = 24 * 60 * 60
        log.record(entry("new", after: 29 * day), now: start.addingTimeInterval(29 * day))
        #expect(log.entries.map(\.id) == ["new", "kept", "old"])

        // "old" was logged at `start`, "kept" a second after it.
        log.trim(now: start.addingTimeInterval(30 * day + 0.5))

        #expect(log.entries.map(\.id) == ["new", "kept"])
    }

    @Test func theLogRoundTripsThroughJSON() throws {
        var log = log("a", "b")
        log.record(entry("c", after: 2.25, posted: false), now: start.addingTimeInterval(60))
        log.markRead(["a"])

        let data = try JSONEncoder().encode(log)

        #expect(try JSONDecoder().decode(NotificationLog.self, from: data) == log)
    }
}
