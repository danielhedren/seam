import Foundation
import GitKit

/// What a notification can be about (SPEC §7.10); each can be turned off in Settings.
public enum NotificationKind: String, CaseIterable, Codable, Sendable {
    case agent, checks, review, comment, readyToMerge, closed

    /// The kinds that need pull requests read, in the background too.
    public var needsPullRequests: Bool { self != .agent }
}

/// Something that changed and needs the author, found by comparing two snapshots.
public struct NotificationEvent: Equatable, Sendable {
    public enum What: Equatable, Sendable {
        /// An agent answered or asked in a Seam thread; `thread` is its id.
        case agent(thread: String, author: String, body: String)
        case checksFailed(PullRequest)
        case checksPassed(PullRequest)
        /// A review's verdict, or its own words.
        case review(PullRequest, GitHubConversationItem)
        /// Comments by others, in the conversation or on lines; `thread` is the first comment's
        /// GitHub thread id when it is on lines.
        case comments(PullRequest, [Comment])
        case readyToMerge(PullRequest)
        case merged(PullRequest)
        case closed(PullRequest)
    }

    public struct Comment: Equatable, Sendable {
        public var author: String
        public var body: String
        public var thread: String?

        public init(author: String, body: String, thread: String? = nil) {
            self.author = author
            self.body = body
            self.thread = thread
        }
    }

    public var worktree: String
    public var what: What

    public var kind: NotificationKind {
        switch what {
        case .agent: .agent
        case .checksFailed, .checksPassed: .checks
        case .review: .review
        case .comments: .comment
        case .readyToMerge: .readyToMerge
        case .merged, .closed: .closed
        }
    }
}

/// What notifications compare: per worktree, what awaits the author and its pull request as
/// last read. Words by the author themselves are left out when it's built.
public struct NotificationSnapshot: Equatable, Sendable {
    public struct Worktree: Equatable, Sendable {
        /// Seam threads awaiting the author: id → its latest comment.
        public var awaiting: [String: ThreadComment] = [:]
        public var pullRequest: PullRequest?
        /// Whether the PR's threads and conversation have been read, so a first read isn't news.
        public var discussionRead = false
        /// GitHub comments by others, by GitHub comment id, on lines (with their thread's id).
        public var gitHubComments: [Int: NotificationEvent.Comment] = [:]
        /// The conversation's entries by others, by kind and id.
        public var conversation: [String: GitHubConversationItem] = [:]

        public init(
            awaiting: [String: ThreadComment] = [:], pullRequest: PullRequest? = nil,
            discussionRead: Bool = false, gitHubComments: [Int: NotificationEvent.Comment] = [:],
            conversation: [GitHubConversationItem] = []
        ) {
            self.awaiting = awaiting
            self.pullRequest = pullRequest
            self.discussionRead = discussionRead
            self.gitHubComments = gitHubComments
            self.conversation = Dictionary(
                conversation.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public var worktrees: [String: Worktree]

    public init(worktrees: [String: Worktree] = [:]) {
        self.worktrees = worktrees
    }
}

extension GitHubConversationItem {
    /// A comment and a review can share a database id.
    public var key: String { "\(kind == .comment ? "c" : "r")\(id)" }
}

/// Snapshot to snapshot, what's news (SPEC §7.10). Pure: the session builds the snapshots and
/// decides what to post.
public enum NotificationRules {
    public static func events(from old: NotificationSnapshot, to new: NotificationSnapshot)
        -> [NotificationEvent]
    {
        new.worktrees.sorted { $0.key < $1.key }.flatMap { path, now -> [NotificationEvent] in
            // A worktree seen for the first time has no news, only a state.
            guard let before = old.worktrees[path] else { return [] }
            return events(before, now).map { NotificationEvent(worktree: path, what: $0) }
        }
    }

    private static func events(
        _ before: NotificationSnapshot.Worktree, _ now: NotificationSnapshot.Worktree
    ) -> [NotificationEvent.What] {
        var events: [NotificationEvent.What] = now.awaiting.sorted { $0.key < $1.key }
            .compactMap { id, latest in
                before.awaiting[id]?.id == latest.id
                    ? nil : .agent(thread: id, author: latest.author, body: latest.body)
            }
        guard let pullRequest = now.pullRequest, let last = before.pullRequest,
            last.number == pullRequest.number
        else { return events }

        if last.checks.pending > 0, pullRequest.checks.pending == 0, pullRequest.state == .open {
            if pullRequest.checks.failed > 0 {
                events.append(.checksFailed(pullRequest))
            } else if pullRequest.checks.passed > 0 {
                events.append(.checksPassed(pullRequest))
            }
        }
        if before.discussionRead {
            let added = now.conversation.values.filter { before.conversation[$0.key] == nil }
                .sorted { $0.created < $1.created }
            events += added.filter { $0.kind != .comment }.map { .review(pullRequest, $0) }
            let comments =
                added.filter { $0.kind == .comment }.map {
                    NotificationEvent.Comment(author: $0.author, body: $0.body)
                }
                + now.gitHubComments.sorted { $0.key < $1.key }
                .filter { before.gitHubComments[$0.key] == nil }.map(\.value)
            if !comments.isEmpty { events.append(.comments(pullRequest, comments)) }
        }
        if !last.isReadyToMerge, pullRequest.isReadyToMerge {
            events.append(.readyToMerge(pullRequest))
        }
        if last.state == .open {
            switch pullRequest.state {
            case .merged: events.append(.merged(pullRequest))
            case .closed: events.append(.closed(pullRequest))
            case .open: break
            }
        }
        return events
    }
}
