import Foundation

/// A pull request's comments that aren't on lines, and its reviews' verdicts (SPEC §7.9).
public struct GitHubConversationItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case comment, approved, changesRequested, commented, dismissed
    }

    /// GitHub's database id, unique among a PR's comments and, separately, its reviews.
    public var id: Int
    public var kind: Kind
    public var author: String
    public var body: String
    public var created: Date
    public var url: String

    public init(
        id: Int, kind: Kind = .comment, author: String, body: String, created: Date, url: String
    ) {
        self.id = id
        self.kind = kind
        self.author = author
        self.body = body
        self.created = created
        self.url = url
    }
}

/// What one read of a pull request's discussion returns.
public struct GitHubDiscussion: Equatable, Sendable {
    public var threads: [GitHubReviewThread]
    /// Oldest first; the latest 100 comments and 100 reviews.
    public var conversation: [GitHubConversationItem]
    /// The login gh reads as, so the reader's own words can be told apart.
    public var viewer: String?

    public init(
        threads: [GitHubReviewThread], conversation: [GitHubConversationItem] = [],
        viewer: String? = nil
    ) {
        self.threads = threads
        self.conversation = conversation
        self.viewer = viewer
    }
}
