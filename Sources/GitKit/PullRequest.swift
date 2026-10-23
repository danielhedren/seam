import Foundation

/// A repository on a GitHub host, named the way `gh -R` takes it.
public struct GitHubRepo: Hashable, Codable, Sendable {
    public var host: String
    public var owner: String
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host.lowercased()
        self.owner = owner
        self.name = name
    }

    public var slug: String { "\(host)/\(owner)/\(name)" }

    /// `https://host/owner/name(.git)`, `git@host:owner/name(.git)` or
    /// `ssh://git@host[:port]/owner/name(.git)`. Nil for anything else, such as a local path.
    public static func parse(_ url: String) -> GitHubRepo? {
        var host: Substring
        var path: Substring
        if let scheme = url.range(of: "://") {
            guard ["https", "http", "ssh", "git"].contains(url[..<scheme.lowerBound]) else {
                return nil
            }
            let rest = url[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = rest[..<slash]
            path = rest[rest.index(after: slash)...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let colon = host.firstIndex(of: ":") { host = host[..<colon] }
        } else {
            // scp-like: `[user@]host:owner/name`. A path with a slash before the colon isn't one.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else {
                return nil
            }
            host = url[..<colon]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            path = url[url.index(after: colon)...]
        }
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !host.isEmpty, parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        // GitHub's SSH-over-443 endpoint is github.com itself.
        let name = host.lowercased() == "ssh.github.com" ? "github.com" : String(host)
        return GitHubRepo(host: name, owner: String(parts[0]), name: String(parts[1]))
    }
}

/// A pull request as Seam shows it (SPEC §7.8).
public struct PullRequest: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case open, closed, merged
    }

    /// Where its reviews stand: GitHub's decision where the repo requires reviews, else the
    /// latest review of each reviewer.
    public enum Review: String, Codable, Sendable {
        case none, commented, changesRequested, approved
    }

    public struct Checks: Codable, Equatable, Sendable {
        public var passed = 0
        public var failed = 0
        public var pending = 0
        /// The first failed check's page.
        public var failedURL: String?

        public init(passed: Int = 0, failed: Int = 0, pending: Int = 0, failedURL: String? = nil) {
            self.passed = passed
            self.failed = failed
            self.pending = pending
            self.failedURL = failedURL
        }

        public var total: Int { passed + failed + pending }
    }

    public var number: Int
    public var title: String
    public var url: String
    public var state: State
    public var isDraft: Bool
    /// The branch it merges from, and that branch's owner, which differs for a fork.
    public var head: String
    public var headOwner: String
    public var headCommit: String
    /// The branch it merges into.
    public var base: String
    public var review: Review
    public var checks: Checks
    public var updated: Date

    public init(
        number: Int, title: String, url: String, state: State, isDraft: Bool = false,
        head: String, headOwner: String, headCommit: String, base: String,
        review: Review = .none, checks: Checks = Checks(), updated: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.head = head
        self.headOwner = headOwner
        self.headCommit = headCommit
        self.base = base
        self.review = review
        self.checks = checks
        self.updated = updated
    }
}

extension PullRequest {
    /// The row's marker (SPEC §7.8): one state, the review's only while the PR is open.
    public enum Marker: Equatable, Sendable {
        case draft, waitingForReview, reviewed, approved, merged, closed
    }

    public var marker: Marker {
        switch state {
        case .merged: return .merged
        case .closed: return .closed
        case .open:
            if isDraft { return .draft }
            switch review {
            case .none: return .waitingForReview
            case .commented, .changesRequested: return .reviewed
            case .approved: return .approved
            }
        }
    }

    /// Failed checks only matter while it's open: a merged PR's red run is history.
    public var ciFailed: Bool { state == .open && checks.failed > 0 }
}

/// `gh pr list --json` output (gh's GraphQL names), turned into `PullRequest`.
struct GHPullRequest: Decodable {
    struct Owner: Decodable { var login: String }
    struct LatestReview: Decodable { var state: String }
    /// A CheckRun (`status`, `conclusion`, `detailsUrl`) or a StatusContext (`state`,
    /// `targetUrl`).
    struct Check: Decodable {
        var status: String?
        var conclusion: String?
        var state: String?
        var detailsUrl: String?
        var targetUrl: String?
    }

    /// Cheap enough for a repo's whole list. GitHub charges for every check and review a query
    /// reaches, and `reviewDecision` takes it seconds over a hundred PRs, so those are read per
    /// PR (`detailFields`).
    static let summaryFields = [
        "number", "title", "url", "state", "isDraft", "headRefName", "headRefOid",
        "headRepositoryOwner", "baseRefName", "updatedAt",
    ]
    static let detailFields =
        summaryFields + ["reviewDecision", "latestReviews", "statusCheckRollup"]

    var number: Int
    var title: String
    var url: String
    var state: String
    var isDraft: Bool
    var headRefName: String
    var headRefOid: String
    var headRepositoryOwner: Owner?
    var baseRefName: String
    var reviewDecision: String?
    var latestReviews: [LatestReview]?
    var statusCheckRollup: [Check]?
    var updatedAt: Date

    static func decode(_ data: Data) throws -> [PullRequest] {
        try decoder.decode([GHPullRequest].self, from: data).map(\.pullRequest)
    }

    static func decodeOne(_ data: Data) throws -> PullRequest {
        try decoder.decode(GHPullRequest.self, from: data).pullRequest
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var pullRequest: PullRequest {
        PullRequest(
            number: number, title: title, url: url,
            state: PullRequest.State(rawValue: state.lowercased()) ?? .open, isDraft: isDraft,
            head: headRefName, headOwner: headRepositoryOwner?.login ?? "",
            headCommit: headRefOid, base: baseRefName, review: review, checks: checks,
            updated: updatedAt)
    }

    private var review: PullRequest.Review {
        let states = Set((latestReviews ?? []).map(\.state))
        switch reviewDecision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return states.isEmpty ? .none : .commented
        default:
            if states.contains("CHANGES_REQUESTED") { return .changesRequested }
            if states.contains("APPROVED") { return .approved }
            return states.contains("COMMENTED") ? .commented : .none
        }
    }

    /// Cancelled and skipped checks count for nothing, as on GitHub's own summary. A workflow
    /// waiting for someone to approve its run (`ACTION_REQUIRED`) hasn't failed; it's pending.
    private var checks: PullRequest.Checks {
        var checks = PullRequest.Checks()
        for check in statusCheckRollup ?? [] {
            let outcome = check.conclusion ?? check.state ?? ""
            if let status = check.status, status != "COMPLETED" {
                checks.pending += 1
                continue
            }
            switch outcome {
            case "SUCCESS", "NEUTRAL": checks.passed += 1
            case "FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE":
                checks.failed += 1
                if checks.failedURL == nil {
                    checks.failedURL = check.detailsUrl ?? check.targetUrl
                }
            case "PENDING", "EXPECTED", "ACTION_REQUIRED", "": checks.pending += 1
            default: break
            }
        }
        return checks
    }
}
