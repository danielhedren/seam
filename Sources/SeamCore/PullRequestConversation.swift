import Foundation
import GitKit

/// A worktree's pull request conversation as last read (SPEC §7.9): kept in the GitHub file for
/// `seam`, shown in the thread panel.
public struct PullRequestConversation: Codable, Equatable, Sendable {
    public var repo: GitHubRepo
    public var pullRequest: Int
    public var items: [GitHubConversationItem]
    /// The login gh read as, so the reader's own words can be told apart.
    public var viewer: String?

    public init(
        repo: GitHubRepo, pullRequest: Int, items: [GitHubConversationItem], viewer: String? = nil
    ) {
        self.repo = repo
        self.pullRequest = pullRequest
        self.items = items
        self.viewer = viewer
    }

    /// The command that answers in the conversation; like a thread's reply, the body comes from
    /// a file, so pasting it unwritten fails rather than posting.
    public var gitHubReply: String {
        "gh pr comment \(pullRequest) -R \(repo.slug) --body-file reply.md"
    }
}
