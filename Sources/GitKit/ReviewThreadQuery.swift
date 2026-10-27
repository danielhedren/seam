import Foundation

/// A pull request's review thread as GitHub has it (SPEC §7.9): lines are the original ones,
/// in the commit its first comment's diff hunk shows.
public struct GitHubReviewThread: Codable, Equatable, Sendable {
    public enum Side: String, Codable, Sendable {
        case left, right
    }

    public struct Comment: Codable, Equatable, Sendable {
        /// What the REST API's reply endpoint takes.
        public var id: Int
        public var author: String
        public var body: String
        public var created: Date
        public var url: String
        public var diffHunk: String
        /// The commit it was written on, whose diff its hunk shows.
        public var commit: String?

        public init(
            id: Int, author: String, body: String, created: Date, url: String,
            diffHunk: String = "", commit: String? = nil
        ) {
            self.commit = commit
            self.id = id
            self.author = author
            self.body = body
            self.created = created
            self.url = url
            self.diffHunk = diffHunk
        }
    }

    /// GitHub's node id, which GraphQL's thread mutations take.
    public var id: String
    public var path: String
    public var isResolved: Bool
    public var side: Side
    /// Nil for a comment on the whole file, and for an old one GitHub only knows a position for.
    public var lines: ClosedRange<Int>?
    public var isFileComment: Bool
    public var comments: [Comment]

    public init(
        id: String, path: String, isResolved: Bool = false, side: Side = .right,
        lines: ClosedRange<Int>?, isFileComment: Bool? = nil, comments: [Comment]
    ) {
        self.isFileComment = isFileComment ?? (lines == nil)
        self.id = id
        self.path = path
        self.isResolved = isResolved
        self.side = side
        self.lines = lines
        self.comments = comments
    }
}

/// The fixed queries `gh api graphql` runs (ADR 0006), and their answers.
enum ReviewThreadQuery {
    private static let comments = """
        pageInfo { hasNextPage endCursor }
        nodes { databaseId author { login } body createdAt url diffHunk originalCommit { oid } }
        """

    /// The first page also reads the conversation and who gh reads as.
    static let firstThreads = threads(conversation: true)
    static let threads = threads(conversation: false)

    private static func threads(conversation: Bool) -> String {
        let extra =
            conversation
            ? """
            comments(last: 100) { nodes { databaseId author { login } body createdAt url } }
            reviews(last: 100) {
              nodes { databaseId author { login } body state submittedAt url }
            }
            """ : ""
        return """
            query($owner: String!, $name: String!, $number: Int!, $after: String) {
              \(conversation ? "viewer { login }" : "")
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  \(extra)
                  reviewThreads(first: 100, after: $after) {
                    pageInfo { hasNextPage endCursor }
                    nodes {
                      id isResolved path diffSide startDiffSide originalLine originalStartLine subjectType
                      comments(first: 100) { \(comments) }
                    }
                  }
                }
              }
            }
            """
    }

    /// The rest of one thread's comments, past its first hundred.
    static let moreComments = """
        query($id: ID!, $after: String) {
          node(id: $id) {
            ... on PullRequestReviewThread { comments(first: 100, after: $after) { \(comments) } }
          }
        }
        """

    struct Page<Node: Decodable>: Decodable {
        struct Info: Decodable {
            var hasNextPage: Bool
            var endCursor: String?
        }
        var pageInfo: Info
        var nodes: [Node]
    }

    struct Comment: Decodable {
        struct Author: Decodable { var login: String }
        struct Commit: Decodable { var oid: String }
        var databaseId: Int
        var author: Author?
        var body: String
        var createdAt: Date
        var url: String
        var diffHunk: String?
        var originalCommit: Commit?

        var comment: GitHubReviewThread.Comment {
            // A deleted account's comments have no author; GitHub shows them as "ghost".
            GitHubReviewThread.Comment(
                id: databaseId, author: author?.login ?? "ghost", body: body, created: createdAt,
                url: url, diffHunk: diffHunk ?? "", commit: originalCommit?.oid)
        }
    }

    struct Thread: Decodable {
        var id: String
        var isResolved: Bool
        var path: String
        var diffSide: String?
        var startDiffSide: String?
        var originalLine: Int?
        var originalStartLine: Int?
        var subjectType: String?
        var comments: Page<Comment>

        var thread: GitHubReviewThread {
            var lines: ClosedRange<Int>?
            if subjectType != "FILE", let end = originalLine {
                // A range starting on the other side can't be one side's lines; GitHub shows it
                // at its last line.
                let sameSide = startDiffSide == nil || startDiffSide == diffSide
                lines = sameSide ? min(originalStartLine ?? end, end)...end : end...end
            }
            return GitHubReviewThread(
                id: id, path: path, isResolved: isResolved,
                side: diffSide == "LEFT" ? .left : .right, lines: lines,
                isFileComment: subjectType == "FILE",
                comments: comments.nodes.map(\.comment))
        }
    }

    struct ConversationComment: Decodable {
        var databaseId: Int
        var author: Comment.Author?
        var body: String
        var createdAt: Date
        var url: String

        var item: GitHubConversationItem {
            GitHubConversationItem(
                id: databaseId, author: author?.login ?? "ghost", body: body, created: createdAt,
                url: url)
        }
    }

    struct Review: Decodable {
        var databaseId: Int
        var author: Comment.Author?
        var body: String
        var state: String
        var submittedAt: Date?
        var url: String

        /// Nil for a pending review, which only its author sees, and for a plain "commented"
        /// one: that's the wrapper of line comments, which show as threads.
        var item: GitHubConversationItem? {
            let kind: GitHubConversationItem.Kind
            switch state {
            case "APPROVED": kind = .approved
            case "CHANGES_REQUESTED": kind = .changesRequested
            case "DISMISSED": kind = .dismissed
            case "COMMENTED" where !body.isEmpty: kind = .commented
            default: return nil
            }
            guard let submittedAt else { return nil }
            return GitHubConversationItem(
                id: databaseId, kind: kind, author: author?.login ?? "ghost", body: body,
                created: submittedAt, url: url)
        }
    }

    struct ThreadsAnswer: Decodable {
        struct Data: Decodable {
            var viewer: Comment.Author?
            var repository: Repository?
        }
        struct Repository: Decodable { var pullRequest: PullRequest? }
        struct PullRequest: Decodable {
            var reviewThreads: Page<Thread>
            var comments: Nodes<ConversationComment>?
            var reviews: Nodes<Review>?

            /// Oldest first.
            var conversation: [GitHubConversationItem] {
                ((comments?.nodes ?? []).map(\.item) + (reviews?.nodes ?? []).compactMap(\.item))
                    .sorted { $0.created < $1.created }
            }
        }
        struct Nodes<Node: Decodable>: Decodable { var nodes: [Node] }
        var data: Data
    }

    struct CommentsAnswer: Decodable {
        struct Data: Decodable { var node: Node? }
        struct Node: Decodable { var comments: Page<Comment>? }
        var data: Data
    }

    static func decode<Answer: Decodable>(_ type: Answer.Type, _ data: Foundation.Data) throws
        -> Answer
    {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
