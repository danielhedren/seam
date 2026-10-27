import Foundation

/// A repo's threads as the store holds them (SPEC §7.7, §7.9): Seam's own, and the pull
/// requests' threads and conversations as the app last read them. For front ends that read the
/// store rather than run the app's models, like `seam`.
public struct ThreadListing: Sendable {
    public var threads: [ReviewThread]
    /// When each worktree's pull request was read.
    public var read: [String: Date]
    public var conversations: [String: PullRequestConversation]

    public init(store: ThreadStore, repository: Repository) throws(ThreadError) {
        let github = try store.gitHubThreads(for: repository)
        threads = try store.threads(for: repository) + github.threads
        read = github.read
        conversations = github.conversations
    }

    public func thread(_ id: String) -> ReviewThread? {
        threads.first { $0.id == id }
    }

    /// Why `seam` can't change a GitHub thread, with the command that answers it there; nil for
    /// a thread it can change.
    public func refusal(for id: String) -> String? {
        guard let thread = thread(id), !thread.capabilities.contains(.reply),
            let github = thread.github, let reply = thread.gitHubReply
        else { return nil }
        return "#\(id) is a thread on GitHub pull request #\(github.pullRequest), which seam can't "
            + "change. Answer it on GitHub: write your reply to reply.md, then run\n  \(reply)"
    }

    /// One worktree's conversation as text, or with `nil` every worktree's, each naming its
    /// worktree; those `since` leaves empty are left out.
    public func conversationTexts(worktree: String?, since: Date?) -> [String] {
        conversations.sorted { $0.key < $1.key }
            .filter { worktree == nil || $0.key == worktree }
            .compactMap { key, conversation in
                ThreadText.format(
                    conversation, showsWorktree: worktree == nil ? key : nil, since: since,
                    read: read[key])
            }
    }

    /// Where a thread's new-side lines are in its worktree's file now, by the app's rules
    /// (SPEC §7.7), reading only that file; nil for the old side, which `ThreadText` explains.
    public static func placement(
        of thread: ReviewThread, fileSystem: any FileSystem = LocalFileSystem()
    ) -> ThreadPlacement? {
        guard thread.anchor.side == .new else { return nil }
        let path = thread.anchor.path
        let file = URL(fileURLWithPath: thread.worktree).appending(path: path)
        guard let data = try? fileSystem.contents(of: file) else { return .notShown }
        let lines = TextLines.split(String(decoding: data, as: UTF8.self))
        let context = ThreadPlacer.Context(paths: [path], text: { _, _ in lines })
        return ThreadPlacer.place([thread], in: context).first?.placement
    }
}
