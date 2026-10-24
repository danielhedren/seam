import Foundation

/// Where a thread came from: Seam's own store, or a pull request read from GitHub (SPEC §7.9).
public enum ThreadSource: Hashable, Sendable {
    case seam, gitHub
}

/// What may be done to a thread. A pull request's threads are only read (ADR 0006), so every
/// view, command and `seam` asks here rather than checking where a thread came from.
public struct ThreadCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let reply = ThreadCapabilities(rawValue: 1 << 0)
    public static let resolve = ThreadCapabilities(rawValue: 1 << 1)
    public static let delete = ThreadCapabilities(rawValue: 1 << 2)
    /// It has a page elsewhere to open.
    public static let openRemote = ThreadCapabilities(rawValue: 1 << 3)
    /// It knows the commit it was written on.
    public static let jumpToCommit = ThreadCapabilities(rawValue: 1 << 4)
}

extension ReviewThread {
    public var source: ThreadSource { github == nil ? .seam : .gitHub }

    public var capabilities: ThreadCapabilities {
        guard let github else { return [.reply, .resolve, .delete] }
        return github.commit == nil ? [.openRemote] : [.openRemote, .jumpToCommit]
    }
}

/// Who the reader is in threads: their git email, or "you" (SPEC §7.7).
public struct ReviewerIdentity: Equatable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }

    public func wrote(_ comment: ThreadComment) -> Bool {
        comment.author == name || comment.author == ReviewThread.reader
    }

    /// An open thread whose latest word is someone else's: an agent's answer, or a request.
    public func awaitsReply(_ thread: ReviewThread) -> Bool {
        guard !thread.isResolved, let latest = thread.comments.last else { return false }
        return !wrote(latest)
    }
}
