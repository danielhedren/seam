import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// The bell (SPEC §7.10): news is logged whether or not it's posted, read once the reader has
/// seen it, counted on the Dock icon, and kept across launches.
@MainActor @Suite(.timeLimit(.minutes(1))) struct NotificationBellTests {
    /// A repo's window where the reader asks on a line and an agent answers.
    @MainActor private struct Window {
        let repo: FixtureRepo
        let session: RepoSession
        let review: WorktreeReview
        let threads: ThreadStore
        let watcher = ManualWatcher()

        var bell: NotificationBell { session.services.notifications }

        init(_ repo: FixtureRepo, bell: NotificationBell? = nil) async throws {
            self.repo = repo
            threads = scratchThreadStore()
            var services = services(
                repo.git, watcher: watcher, threads: threads, platform: RecordingPlatform())
            if let bell { services.notifications = bell }
            session = RepoSession(directory: repo.main, services: services)
            await session.open()
            await session.settled()
            review = try #require(session.selected)
        }

        /// The id of the entry logged for the agent's answer, and its thread.
        func agentAnswers(line: Int = 1, _ body: String = "Done.") async throws
            -> (entry: String, thread: String)
        {
            let repository = try #require(session.repository)
            session.draft = ThreadDraft(
                worktree: review.id,
                anchor: try #require(review.anchor(path: "a.txt", side: .new, lines: line...line)))
            await session.post("Why?")
            let thread = try #require(session.selectedThreadID)
            session.closeThread()
            try threads.update(repository) { threads throws(ThreadError) in
                try ThreadRules.reply(&threads, to: thread, author: "claude", body: body, now: .now)
            }
            watcher.send([threads.file(for: repository).path])
            let entry = "\(review.id)|agent-\(thread)"
            await until { bell.log.entries.contains { $0.id == entry } }
            return (entry, thread)
        }
    }

    private func window(bell: NotificationBell? = nil) async throws -> Window {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\ntwo\nthree\n")
        return try await Window(repo, bell: bell)
    }

    @Test func newsWhileSeamIsInFrontIsLoggedWithoutABanner() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        window.session.noteActivation(true)

        let (id, thread) = try await window.agentAnswers()

        let entry = try #require(window.bell.log.entries.first)
        #expect(window.bell.log.entries.count == 1)
        #expect(entry.id == id)
        #expect(entry.title == "main")
        #expect(entry.body == "claude: Done.")
        #expect(entry.url == SeamURL(path: window.review.id, thread: thread).url)
        #expect(!entry.isRead)
        #expect(!entry.wasPosted)
        #expect(platform.notified == [])
        window.session.close()
    }

    @Test func newsInTheBackgroundIsLoggedAndPosted() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        window.session.noteActivation(false)

        let (id, _) = try await window.agentAnswers()

        #expect(platform.notified.map(\.id) == [id])
        #expect(window.bell.log.entries.map(\.id) == [id])
        #expect(window.bell.log.entries.first?.wasPosted == true)
        window.session.close()
    }

    @Test func aKindTurnedOffIsNotLogged() async throws {
        let window = try await window()
        window.session.settings.notifications.remove(.agent)
        let repository = try #require(window.session.repository)
        window.session.draft = ThreadDraft(
            worktree: window.review.id,
            anchor: try #require(window.review.anchor(path: "a.txt", side: .new, lines: 1...1)))
        await window.session.post("Why?")
        let thread = try #require(window.session.selectedThreadID)
        try window.threads.update(repository) { threads throws(ThreadError) in
            try ThreadRules.reply(&threads, to: thread, author: "claude", body: "So.", now: .now)
        }
        window.watcher.send([window.threads.file(for: repository).path])
        await until {
            window.session.lastSnapshot.worktrees[window.review.id]?.awaiting[thread] != nil
        }

        #expect(window.bell.log.entries == [])
        window.session.close()
    }

    @Test func openingTheThreadMarksItsEntryReadAndRemovesItsNotification() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        window.session.noteActivation(false)
        let (first, thread) = try await window.agentAnswers(line: 1)
        let (second, _) = try await window.agentAnswers(line: 2)
        #expect(platform.delivered == [first, second])

        window.session.openThread(thread)

        #expect(window.bell.log.entries.map(\.id) == [second, first])
        #expect(window.bell.log.entries.map(\.isRead) == [false, true])
        #expect(platform.removed == [first])
        #expect(platform.delivered == [second])
        window.session.close()
    }

    @Test func aClickInNotificationCenterMarksTheEntryRead() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        window.session.noteActivation(false)
        let (first, _) = try await window.agentAnswers(line: 1)
        let (second, _) = try await window.agentAnswers(line: 2)

        await window.bell.clicked(second, on: platform)

        #expect(window.bell.log.entries.map(\.id) == [second, first])
        #expect(window.bell.log.entries.map(\.isRead) == [true, false])
        #expect(window.bell.log.unreadCount == 1)
        #expect(platform.removed == [second])
        window.session.close()
    }

    @Test func clickingAnEntryInTheBellOpensWhatItsAboutAndMarksItRead() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        let (first, thread) = try await window.agentAnswers(line: 1)
        let (second, _) = try await window.agentAnswers(line: 2)
        window.session.showsNotifications = true
        #expect(window.bell.log.unreadCount == 2, "showing the popover marks nothing")

        window.session.openNotification(try #require(window.bell.log.entries.last))

        #expect(platform.opened == [SeamURL(path: window.review.id, thread: thread).url])
        #expect(window.bell.log.entries.map(\.id) == [second, first])
        #expect(window.bell.log.entries.map(\.isRead) == [false, true])
        #expect(!window.session.showsNotifications)
        // Logged in front, it had no notification to take away.
        #expect(platform.removed == [])
        window.session.close()
    }

    @Test func theCommandsShowTheBellOpenTheNewestUnreadAndMarkAllRead() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        let session = window.session
        func command(_ id: String) throws -> SeamCommand { try #require(CommandCatalog.byID[id]) }
        #expect(try command("notifications").shortcutLabel == "⇧⌘N")
        #expect(try command("next-notification").shortcutLabel == "⌥⌘N")
        #expect(try !command("next-notification").isEnabled(session))
        #expect(try !command("notifications-read").isEnabled(session))
        session.noteActivation(false)
        let (first, _) = try await window.agentAnswers(line: 1)
        let (second, secondThread) = try await window.agentAnswers(line: 2)
        let (third, thirdThread) = try await window.agentAnswers(line: 3)

        try command("notifications").run(session)
        #expect(session.showsNotifications)

        #expect(try command("next-notification").isEnabled(session))
        try command("next-notification").run(session)
        try command("next-notification").run(session)
        #expect(
            platform.opened == [
                SeamURL(path: window.review.id, thread: thirdThread).url,
                SeamURL(path: window.review.id, thread: secondThread).url,
            ])
        #expect(window.bell.log.entries.map(\.isRead) == [true, true, false])

        try command("notifications-read").run(session)
        #expect(window.bell.log.unreadCount == 0)
        #expect(platform.removed == [third, second, first])
        #expect(window.bell.log.entries.map(\.id) == [third, second, first])
        #expect(platform.delivered == [])
        #expect(try !command("notifications-read").isEnabled(session))
        session.close()
    }

    @Test func theDockBadgeFollowsTheUnreadCountAndItsSwitch() async throws {
        let window = try await window()
        let platform = try #require(window.session.platform)
        #expect(platform.badges == [])

        let (_, thread) = try await window.agentAnswers(line: 1)
        _ = try await window.agentAnswers(line: 2)
        #expect(platform.badges == [1, 2])

        window.session.openThread(thread)
        #expect(platform.badges == [1, 2, 1])

        window.session.settings.badgesDock = false
        await until { platform.badges == [1, 2, 1, 0] }
        _ = try await window.agentAnswers(line: 3)
        #expect(platform.badges == [1, 2, 1, 0])

        window.session.settings.badgesDock = true
        await until { platform.badges == [1, 2, 1, 0, 2] }
        window.bell.markAllRead(on: platform)
        #expect(platform.badges == [1, 2, 1, 0, 2, 0])
        window.session.close()
    }

    @Test func theLogHoldsAtTwoHundredEntries() async throws {
        let platform = RecordingPlatform()
        let bell = NotificationBell(now: { Date(timeIntervalSince1970: 1_800_000_000) })
        for index in 0..<205 {
            bell.record(
                SeamNotification(
                    id: "/repo|ready-\(index)", group: "/repo", title: "feature",
                    body: "#\(index) is ready to merge", url: nil),
                posted: false, on: platform)
        }
        #expect(bell.log.entries.count == 200)
        #expect(bell.log.entries.first?.id == "/repo|ready-204")
        #expect(bell.log.entries.last?.id == "/repo|ready-5")
        #expect(platform.badges.last == 200)
    }

    @Test func theLogSurvivesARelaunch() async throws {
        let root = Scratch.path("seam-events")
        let window = try await window(
            bell: NotificationBell(store: JSONNotificationLogStore(root: root)))
        window.session.noteActivation(false)
        let (first, thread) = try await window.agentAnswers(line: 1)
        let (second, _) = try await window.agentAnswers(line: 2)
        window.session.openThread(thread)
        await window.bell.saved()
        let before = window.bell.log
        #expect(before.entries.map(\.id) == [second, first])
        window.session.close()

        let relaunched = try await Window(
            window.repo, bell: NotificationBell(store: JSONNotificationLogStore(root: root)))

        #expect(relaunched.bell.log == before)
        #expect(relaunched.bell.log.entries.map(\.isRead) == [false, true])
        #expect(relaunched.session.platform?.badges == [1])
        #expect(relaunched.bell.problem == nil)
        relaunched.session.close()
    }

    @Test func anUnreadableLogIsMovedAsideAndSaidSo() async throws {
        let root = Scratch.path("seam-events")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "events.json")
        try Data("{ not json".utf8).write(to: file)
        let bell = NotificationBell(store: JSONNotificationLogStore(root: root))
        let platform = RecordingPlatform()

        await bell.load(on: platform)

        let kept = root.appending(path: "events.json.unreadable")
        #expect(bell.log.entries == [])
        #expect(
            bell.problem
                == "Seam couldn't read its notification log, so the bell starts empty. The old file is kept as \(kept.path)."
        )
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ not json")

        bell.record(
            SeamNotification(id: "/r|ready-1", group: "/r", title: "main", body: "Ready", url: nil),
            posted: false, on: platform)
        await bell.saved()
        let reread = await JSONNotificationLogStore(root: root).load()
        #expect(reread.log == bell.log)
        #expect(reread.problem == nil)
        bell.dismissProblem()
        #expect(bell.problem == nil)
    }

    /// News logged before the saved log arrives stays, on top of what was saved.
    @Test func newsBeforeTheLogIsReadIsKeptWithIt() async throws {
        let root = Scratch.path("seam-events")
        let platform = RecordingPlatform()
        func news(_ number: Int) -> SeamNotification {
            SeamNotification(
                id: "/r|ready-\(number)", group: "/r", title: "main",
                body: "#\(number) is ready to merge", url: nil)
        }
        let first = NotificationBell(store: JSONNotificationLogStore(root: root))
        await first.load(on: platform)
        first.record(news(1), posted: false, on: platform)
        await first.saved()

        let second = NotificationBell(store: JSONNotificationLogStore(root: root))
        second.record(news(2), posted: false, on: platform)
        await second.saved()
        await second.load(on: platform)
        await second.saved()

        #expect(second.log.entries.map(\.id) == ["/r|ready-2", "/r|ready-1"])
        let reread = await JSONNotificationLogStore(root: root).load()
        #expect(reread.log == second.log)
    }
}
