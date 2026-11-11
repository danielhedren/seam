import Foundation
import GitKit

/// What the pull request list hides (SPEC §7.2.2), kept per repo.
public struct PullRequestFilter: Codable, Equatable, Sendable {
    public var hidesDrafts = false
    public var hidesBots = false
    public var onlyReviewRequests = false
    public var hiddenAuthors: Set<String> = []
    public var hiddenLabels: Set<String> = []
    /// Single PRs hidden by hand, until they close.
    public var hiddenNumbers: Set<Int> = []

    public init(
        hidesDrafts: Bool = false, hidesBots: Bool = false, onlyReviewRequests: Bool = false,
        hiddenAuthors: Set<String> = [], hiddenLabels: Set<String> = [],
        hiddenNumbers: Set<Int> = []
    ) {
        self.hidesDrafts = hidesDrafts
        self.hidesBots = hidesBots
        self.onlyReviewRequests = onlyReviewRequests
        self.hiddenAuthors = hiddenAuthors
        self.hiddenLabels = hiddenLabels
        self.hiddenNumbers = hiddenNumbers
    }

    /// A filter saved before a field existed leaves it at its default.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) throws -> Value {
            try values.decodeIfPresent(Value.self, forKey: key) ?? fallback
        }
        self.init(
            hidesDrafts: try value(.hidesDrafts, false), hidesBots: try value(.hidesBots, false),
            onlyReviewRequests: try value(.onlyReviewRequests, false),
            hiddenAuthors: try value(.hiddenAuthors, []),
            hiddenLabels: try value(.hiddenLabels, []),
            hiddenNumbers: try value(.hiddenNumbers, []))
    }

    public var isEmpty: Bool { self == PullRequestFilter() }

    func hides(_ pullRequest: PullRequest, isRequested: Bool) -> Bool {
        (hidesDrafts && pullRequest.isDraft) || (hidesBots && pullRequest.isFromBot)
            || (onlyReviewRequests && !isRequested) || hiddenAuthors.contains(pullRequest.author)
            || pullRequest.labels.contains(where: hiddenLabels.contains)
            || hiddenNumbers.contains(pullRequest.number)
    }
}

extension PullRequest {
    /// gh marks GitHub Apps; a bot account is only known by its login.
    public var isFromBot: Bool { authorIsBot || author.hasSuffix("[bot]") }
}

/// The pull request list's rows (SPEC §7.2.2): other people's open PRs that no worktree here
/// has checked out, filtered, review requests first, then the most recently updated.
public struct PullRequestListing: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var pullRequest: PullRequest
        public var isReviewRequested: Bool
        /// Listed only because Show Hidden is on.
        public var isHidden: Bool

        public var id: Int { pullRequest.number }
    }

    public static let limit = 100

    public var rows: [Row]
    /// How many the filters hide.
    public var hidden: Int
    /// How many pass the filters, of which at most `limit` are listed.
    public var matching: Int
    /// The authors and labels among the PRs the list could show, for the filter menu.
    public var authors: [String]
    public var labels: [String]

    public var isCapped: Bool { matching > Self.limit }

    public init(
        open: [PullRequest], viewer: String?, reviewRequests: Set<Int>, checkedOut: Set<Int>,
        filter: PullRequestFilter, showsHidden: Bool = false
    ) {
        let candidates = open.filter { pullRequest in
            pullRequest.state == .open && !checkedOut.contains(pullRequest.number)
                && viewer.map { pullRequest.author.caseInsensitiveCompare($0) != .orderedSame }
                    != false
        }
        .sorted { lhs, rhs in
            let (left, right) = (
                reviewRequests.contains(lhs.number), reviewRequests.contains(rhs.number)
            )
            if left != right { return left }
            return lhs.updated == rhs.updated ? lhs.number > rhs.number : lhs.updated > rhs.updated
        }
        var shown: [Row] = []
        var hiddenRows: [Row] = []
        for pullRequest in candidates {
            let requested = reviewRequests.contains(pullRequest.number)
            let hides = filter.hides(pullRequest, isRequested: requested)
            let row = Row(pullRequest: pullRequest, isReviewRequested: requested, isHidden: hides)
            if hides { hiddenRows.append(row) } else { shown.append(row) }
        }
        matching = shown.count
        hidden = hiddenRows.count
        rows =
            Array(shown.prefix(Self.limit))
            + (showsHidden ? Array(hiddenRows.prefix(Self.limit)) : [])
        authors = Set(candidates.map(\.author).filter { !$0.isEmpty }).union(filter.hiddenAuthors)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        labels = Set(candidates.flatMap(\.labels)).union(filter.hiddenLabels)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
