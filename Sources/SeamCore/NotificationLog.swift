import Foundation

/// The news the bell keeps (SPEC §7.10), newest first: the newest 200 entries of the last 30
/// days, for every repo.
public struct NotificationLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        /// The notification's id; newer news with the same id replaces the entry.
        public var id: String
        public var group: String
        public var title: String
        public var body: String
        /// The `seam://open` link to what it's about.
        public var url: URL?
        public var date: Date
        public var isRead: Bool
        /// Whether a notification went to Notification Center, to take out once it's read.
        public var wasPosted: Bool

        public init(
            id: String, group: String, title: String, body: String, url: URL?, date: Date,
            isRead: Bool = false, wasPosted: Bool
        ) {
            self.id = id
            self.group = group
            self.title = title
            self.body = body
            self.url = url
            self.date = date
            self.isRead = isRead
            self.wasPosted = wasPosted
        }
    }

    public static let limit = 200
    public static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    public var unreadCount: Int { entries.count { !$0.isRead } }

    public var newestUnread: Entry? { entries.first { !$0.isRead } }

    public mutating func record(_ entry: Entry, now: Date) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        trim(now: now)
    }

    /// The entries this made read, as they were.
    @discardableResult
    public mutating func markRead(_ ids: Set<String>) -> [Entry] {
        var read: [Entry] = []
        for index in entries.indices where !entries[index].isRead && ids.contains(entries[index].id)
        {
            read.append(entries[index])
            entries[index].isRead = true
        }
        return read
    }

    @discardableResult
    public mutating func markAllRead() -> [Entry] {
        markRead(Set(entries.map(\.id)))
    }

    public mutating func trim(now: Date) {
        let oldest = now.addingTimeInterval(-Self.maxAge)
        entries.removeAll { $0.date < oldest }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
}
