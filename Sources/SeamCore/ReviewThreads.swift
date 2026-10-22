import Foundation

/// Where a thread sits (SPEC §7.7): a file, a side and a line range, with the lines' text so it
/// can follow the file as it changes.
public struct ThreadAnchor: Codable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable {
        case new, old
    }

    public var path: String
    public var side: Side
    /// One-based and inclusive, as when the thread was opened.
    public var lines: ClosedRange<Int>
    public var text: [String]

    public init(path: String, side: Side, lines: ClosedRange<Int>, text: [String]) {
        self.path = path
        self.side = side
        self.lines = lines
        self.text = text
    }

    /// The anchor's lines read from `file`; nil when the range runs past its end.
    public init?(path: String, side: Side, lines: ClosedRange<Int>, in file: [Substring]) {
        guard lines.lowerBound >= 1, lines.upperBound <= file.count else { return nil }
        self.init(
            path: path, side: side, lines: lines,
            text: file[(lines.lowerBound - 1)...(lines.upperBound - 1)].map(String.init))
    }

    /// Where the anchored lines are in `file` now: the occurrence nearest the original place, or
    /// nil when they're gone and the thread is outdated.
    public func locate(in file: [Substring]) -> ClosedRange<Int>? {
        guard !text.isEmpty, text.count <= file.count else { return nil }
        let starts = (0...(file.count - text.count)).filter { start in
            text.indices.allSatisfy { file[start + $0] == text[$0] }
        }
        let original = lines.lowerBound - 1
        guard let start = starts.min(by: { abs($0 - original) < abs($1 - original) }) else {
            return nil
        }
        return (start + 1)...(start + text.count)
    }
}

public struct ThreadComment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var author: String
    /// Markdown.
    public var body: String
    public var date: Date

    public init(id: String, author: String, body: String, date: Date) {
        self.id = id
        self.author = author
        self.body = body
        self.date = date
    }
}

public struct ReviewThread: Codable, Equatable, Sendable, Identifiable {
    /// What the reader is called in threads; agents give their own names.
    public static let reader = "you"

    public var id: String
    /// The worktree's path; one repo's file holds every worktree's threads.
    public var worktree: String
    public var anchor: ThreadAnchor
    /// Whoever opened it.
    public var author: String
    public var isResolved = false
    public var comments: [ThreadComment]
    /// The last change of any kind; files written before it was kept have none.
    public var updated: Date?

    /// When the thread last changed, for `seam threads --since`: the latest comment when an
    /// older file has no `updated`.
    public var lastActivity: Date {
        updated ?? comments.map(\.date).max() ?? .distantPast
    }

    public init(
        id: String, worktree: String, anchor: ThreadAnchor, author: String,
        isResolved: Bool = false, comments: [ThreadComment], updated: Date? = nil
    ) {
        self.updated = updated
        self.id = id
        self.worktree = worktree
        self.anchor = anchor
        self.author = author
        self.isResolved = isResolved
        self.comments = comments
    }
}

public enum ThreadError: Error, Equatable, Sendable {
    case unknownThread(String)
    case emptyComment
    /// The store was written by a newer Seam; it isn't touched.
    case unsupportedVersion(Int)
    case unreadable(String)
    case unwritable(String)
}

/// The rules for changing threads, as pure functions over the list (SPEC §7.7).
public enum ThreadRules {
    public static func open(
        _ threads: inout [ReviewThread], worktree: String, anchor: ThreadAnchor, author: String,
        body: String, now: Date, newID: () -> String = ThreadRules.newID
    ) throws(ThreadError) -> ReviewThread {
        let body = try checked(body)
        var id = newID()
        while threads.contains(where: { $0.id == id }) { id = newID() }
        let thread = ReviewThread(
            id: id, worktree: worktree, anchor: anchor, author: author,
            comments: [ThreadComment(id: newID(), author: author, body: body, date: now)],
            updated: now)
        threads.append(thread)
        return thread
    }

    /// Anyone may reply; a reply to a resolved thread reopens it.
    public static func reply(
        _ threads: inout [ReviewThread], to id: String, author: String, body: String, now: Date,
        newID: () -> String = ThreadRules.newID
    ) throws(ThreadError) {
        let body = try checked(body)
        let index = try position(of: id, in: threads)
        threads[index].comments.append(
            ThreadComment(id: newID(), author: author, body: body, date: now))
        threads[index].isResolved = false
        threads[index].updated = now
    }

    /// Anyone may resolve, reopen or delete a thread: the agent prompt says whose to leave
    /// alone, and the reader can ask an agent to do any of it.
    public static func setResolved(
        _ resolved: Bool, _ threads: inout [ReviewThread], id: String, now: Date
    ) throws(ThreadError) {
        let index = try position(of: id, in: threads)
        threads[index].isResolved = resolved
        threads[index].updated = now
    }

    /// Removes a thread, returning it and where it was so it can be put back.
    @discardableResult
    public static func delete(_ threads: inout [ReviewThread], id: String) throws(ThreadError)
        -> (thread: ReviewThread, index: Int)
    {
        let index = try position(of: id, in: threads)
        return (threads.remove(at: index), index)
    }

    /// Undoes `delete`; a thread that's back already is left alone.
    public static func restore(
        _ thread: ReviewThread, at index: Int, in threads: inout [ReviewThread]
    ) {
        guard !threads.contains(where: { $0.id == thread.id }) else { return }
        threads.insert(thread, at: min(index, threads.count))
    }

    /// Eight hex digits: short enough to type in `seam reply`, unique within one repo's file.
    public static func newID() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    private static func position(of id: String, in threads: [ReviewThread]) throws(ThreadError)
        -> Int
    {
        guard let index = threads.firstIndex(where: { $0.id == id }) else {
            throw .unknownThread(id)
        }
        return index
    }

    private static func checked(_ body: String) throws(ThreadError) -> String {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw .emptyComment }
        return body
    }
}
