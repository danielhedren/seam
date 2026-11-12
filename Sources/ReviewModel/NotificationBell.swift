import Foundation
import GitKit
import Observation
import SeamCore

/// Where the bell's log is kept across launches (SPEC §11).
public protocol NotificationLogStore: Sendable {
    /// An empty log when there's none or it can't be read, and then why.
    func load() async -> (log: NotificationLog, problem: String?)
    /// Nil when it saved, else why not.
    func save(_ log: NotificationLog) async -> String?
}

/// `events.json` under `~/Library/Application Support/Seam/`.
package actor JSONNotificationLogStore: NotificationLogStore {
    private let file: URL
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "ReviewModel")

    package init(root: URL = AppChoices.stateRoot) {
        file = root.appending(path: "events.json")
    }

    /// A file that won't decode is moved aside rather than overwritten by the next save.
    package func load() -> (log: NotificationLog, problem: String?) {
        guard let data = try? Data(contentsOf: file) else { return (NotificationLog(), nil) }
        do {
            return (try JSONDecoder().decode(NotificationLog.self, from: data), nil)
        } catch {
            logger.error("unreadable \(self.file.path, privacy: .public): \(error)")
            let kept = file.deletingLastPathComponent().appending(path: "events.json.unreadable")
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.moveItem(at: file, to: kept)
            return (
                NotificationLog(),
                String(
                    localized:
                        "Seam couldn't read its notification log, so the bell starts empty. The old file is kept as \(kept.path).",
                    bundle: .module)
            )
        }
    }

    package func save(_ log: NotificationLog) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(log).write(to: file, options: .atomic)
            return nil
        } catch {
            logger.error("could not write \(self.file.path, privacy: .public): \(error)")
            return String(
                localized: "Seam couldn't save its notification log: \(error.localizedDescription)",
                bundle: .module)
        }
    }
}

/// The bell (SPEC §7.10): the app's one log of news, shared by every window. The platform is
/// passed with each call rather than kept, since a window's services name it.
@MainActor
@Observable
public final class NotificationBell {
    package private(set) var log = NotificationLog()
    /// What Seam couldn't read or save of the log, shown in every repo's window (SPEC §11).
    package private(set) var problem: String?
    @ObservationIgnored private var problemIsSaving = false
    @ObservationIgnored private let store: (any NotificationLogStore)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Until the saved log is read, a save would overwrite it with less.
    @ObservationIgnored private var isLoaded = false
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var saveIsWaiting = false
    /// Settings › Notifications: the Dock icon shows the unread count.
    @ObservationIgnored private var badgesDock = true
    @ObservationIgnored private var badge = 0

    /// Without a store the log lasts as long as the app does.
    public init(
        store: (any NotificationLogStore)? = nil, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.now = now
    }

    /// Reads the saved log, once; news logged before it arrived is kept on top.
    package func load(on platform: any PlatformServices) async {
        if loading == nil {
            loading = Task {
                guard let store else { return }
                let (saved, problem) = await store.load()
                var merged = saved
                for entry in log.entries.reversed() { merged.record(entry, now: now()) }
                merged.trim(now: now())
                log = merged
                isLoaded = true
                self.problem = problem
                refreshBadge(on: platform)
                if merged != saved { save() }
            }
        }
        await loading?.value
    }

    package func record(
        _ notification: SeamNotification, posted: Bool, on platform: any PlatformServices
    ) {
        let date = now()
        log.record(
            NotificationLog.Entry(
                id: notification.id, group: notification.group, title: notification.title,
                body: notification.body, url: notification.url, date: date, wasPosted: posted),
            now: date)
        changed(on: platform)
    }

    /// Read entries' notifications leave Notification Center.
    package func markRead(_ ids: Set<String>, on platform: any PlatformServices) {
        finish(log.markRead(ids), on: platform)
    }

    package func markAllRead(on platform: any PlatformServices) {
        finish(log.markAllRead(), on: platform)
    }

    private func finish(_ read: [NotificationLog.Entry], on platform: any PlatformServices) {
        guard !read.isEmpty else { return }
        let posted = read.filter(\.wasPosted).map(\.id)
        if !posted.isEmpty { platform.removeNotifications(posted.sorted()) }
        changed(on: platform)
    }

    /// The reader opened `subject` in Seam, which reads the news about it.
    package func noteOpened(_ subject: NotificationSubject, on platform: any PlatformServices) {
        markRead(Set(log.entries.map(\.id).filter(subject.covers)), on: platform)
    }

    /// A click in the bell: opens what the entry is about, as its notification would.
    package func open(_ entry: NotificationLog.Entry, on platform: any PlatformServices) {
        markRead([entry.id], on: platform)
        if let url = entry.url { platform.open(url) }
    }

    package func openNewestUnread(on platform: any PlatformServices) {
        if let entry = log.newestUnread { open(entry, on: platform) }
    }

    /// A click in Notification Center, which can also be what launches Seam.
    package func clicked(_ id: String, on platform: any PlatformServices) async {
        await load(on: platform)
        markRead([id], on: platform)
    }

    package func setBadgesDock(_ badges: Bool, on platform: any PlatformServices) {
        badgesDock = badges
        refreshBadge(on: platform)
    }

    package func dismissProblem() {
        problem = nil
        problemIsSaving = false
    }

    /// Returns once every change so far is written; tests wait on it.
    package func saved() async {
        while let saving { await saving.value }
    }

    private func changed(on platform: any PlatformServices) {
        refreshBadge(on: platform)
        save()
    }

    private func refreshBadge(on platform: any PlatformServices) {
        let count = badgesDock ? log.unreadCount : 0
        guard count != badge else { return }
        badge = count
        platform.setBadge(count)
    }

    /// Written at once, since nothing runs on ⌘Q; changes made meanwhile go out in one more.
    private func save() {
        guard let store, isLoaded else { return }
        guard saving == nil else {
            saveIsWaiting = true
            return
        }
        let snapshot = log
        saving = Task {
            let failure = await store.save(snapshot)
            saving = nil
            if let failure {
                problem = failure
                problemIsSaving = true
            } else if problemIsSaving {
                dismissProblem()
            }
            if saveIsWaiting {
                saveIsWaiting = false
                save()
            }
        }
    }
}
