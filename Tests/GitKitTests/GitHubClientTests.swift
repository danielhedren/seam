import Foundation
import Testing

@testable import GitKit

@Suite struct GitHubRepoTests {
    @Test(arguments: [
        ("https://github.com/owner/app.git", "github.com/owner/app"),
        ("https://github.com/owner/app", "github.com/owner/app"),
        ("https://user@GitHub.com/owner/app.git/", "github.com/owner/app"),
        ("git@github.com:owner/app.git", "github.com/owner/app"),
        ("ssh://git@github.com/owner/app.git", "github.com/owner/app"),
        ("ssh://git@ssh.github.com:443/owner/app.git", "github.com/owner/app"),
        ("git@code.example.ghe.com:team/tool", "code.example.ghe.com/team/tool"),
    ])
    func remoteURLsNameTheirRepo(url: String, slug: String) {
        #expect(GitHubRepo.parse(url)?.slug == slug)
    }

    @Test(arguments: [
        "/tmp/origin.git", "../origin.git", "file:///tmp/origin.git", "https://github.com/owner",
        "https://github.com/owner/app/extra", "git@github.com:app.git",
    ])
    func anythingElseIsNoRepo(url: String) {
        #expect(GitHubRepo.parse(url) == nil)
    }
}

@Suite struct PullRequestDecodingTests {
    private func decode(_ json: String) throws -> [PullRequest] {
        try GHPullRequest.decode(Data(json.utf8))
    }

    private func pullRequest(
        state: String = "OPEN", draft: Bool = false, decision: String = "null",
        reviews: [String] = [], checks: String = "[]"
    ) -> String {
        let latest = reviews.map { #"{"state":"\#($0)"}"# }.joined(separator: ",")
        return """
            [{"number":12,"title":"Count the lines","url":"https://github.com/owner/app/pull/12",
            "state":"\(state)","isDraft":\(draft),"headRefName":"feature","headRefOid":"abc",
            "headRepositoryOwner":{"id":"1","login":"owner"},"baseRefName":"main",
            "reviewDecision":\(decision),"latestReviews":[\(latest)],
            "statusCheckRollup":\(checks),"updatedAt":"2026-10-23T12:00:00Z"}]
            """
    }

    @Test func anOpenPullRequestReadsWhole() throws {
        let read = try #require(try decode(pullRequest()).first)
        #expect(
            read
                == PullRequest(
                    number: 12, title: "Count the lines",
                    url: "https://github.com/owner/app/pull/12", state: .open, head: "feature",
                    headOwner: "owner", headCommit: "abc", base: "main",
                    updated: Date(timeIntervalSince1970: 1_792_756_800)))
        #expect(read.marker == .waitingForReview)
    }

    @Test func reviewsFollowGitHubsDecisionElseTheLatestReviews() throws {
        func review(_ decision: String, _ reviews: [String]) throws -> PullRequest.Review? {
            try decode(pullRequest(decision: decision, reviews: reviews)).first?.review
        }
        #expect(try review(#""APPROVED""#, []) == .approved)
        #expect(try review(#""CHANGES_REQUESTED""#, ["COMMENTED"]) == .changesRequested)
        #expect(try review(#""REVIEW_REQUIRED""#, []) == PullRequest.Review.none)
        // One approval of two required is still waiting, but it has been reviewed.
        #expect(try review(#""REVIEW_REQUIRED""#, ["APPROVED"]) == .commented)
        #expect(try review("null", ["COMMENTED", "APPROVED"]) == .approved)
        #expect(try review("null", ["APPROVED", "CHANGES_REQUESTED"]) == .changesRequested)
        #expect(try review("null", ["COMMENTED"]) == .commented)
    }

    @Test func markersTellEveryState() throws {
        func marker(_ json: String) throws -> PullRequest.Marker? {
            try decode(json).first?.marker
        }
        #expect(try marker(pullRequest(draft: true, decision: #""APPROVED""#)) == .draft)
        #expect(try marker(pullRequest(reviews: ["COMMENTED"])) == .reviewed)
        #expect(try marker(pullRequest(decision: #""CHANGES_REQUESTED""#)) == .reviewed)
        #expect(try marker(pullRequest(decision: #""APPROVED""#)) == .approved)
        #expect(try marker(pullRequest(state: "MERGED", decision: #""APPROVED""#)) == .merged)
        #expect(try marker(pullRequest(state: "CLOSED")) == .closed)
    }

    @Test func checksCountRunsAndStatusesLikeGitHub() throws {
        let checks = """
            [{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS",
              "detailsUrl":"https://ci/1"},
             {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
             {"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"},
             {"__typename":"CheckRun","status":"COMPLETED","conclusion":"ACTION_REQUIRED"},
             {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null},
             {"__typename":"CheckRun","status":"COMPLETED","conclusion":"TIMED_OUT",
              "detailsUrl":"https://ci/2"},
             {"__typename":"StatusContext","state":"FAILURE","targetUrl":"https://ci/3"},
             {"__typename":"StatusContext","state":"SUCCESS"}]
            """
        let read = try #require(try decode(pullRequest(checks: checks)).first)
        #expect(
            read.checks
                == PullRequest.Checks(passed: 2, failed: 2, pending: 2, failedURL: "https://ci/2"))
        #expect(read.ciFailed)
    }

    @Test func aMergedPullRequestsFailedRunIsHistory() throws {
        let checks = #"[{"status":"COMPLETED","conclusion":"FAILURE"}]"#
        let read = try #require(try decode(pullRequest(state: "MERGED", checks: checks)).first)
        #expect(read.checks.failed == 1)
        #expect(!read.ciFailed)
    }
}

/// The real client against a stand-in `gh` that records how it was run.
@Suite(.timeLimit(.minutes(1))) struct CLIGitHubClientTests {
    private let folder: URL
    private let gh: URL
    private let log: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(
            path: "seam-gh-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        gh = folder.appending(path: "gh")
        log = folder.appending(path: "log")
    }

    /// A `gh` that logs its arguments, prompt setting, GH_REPO and folder, then prints
    /// `output` to stdout and `errors` to stderr and exits with `status`.
    private func script(output: String = "[]", errors: String = "", status: Int32 = 0) throws {
        let text = """
            #!/bin/sh
            printf '%s\\n' "$*" > '\(log.path)'
            printf 'prompt=%s repo=%s\\n' "$GH_PROMPT_DISABLED" "${GH_REPO-unset}" >> '\(log.path)'
            pwd -P >> '\(log.path)'
            cat <<'SEAM_EOF'
            \(output)
            SEAM_EOF
            printf '%s' '\(errors)' >&2
            exit \(status)
            """
        try Data(text.utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
    }

    private func client() -> CLIGitHubClient {
        let gh = gh
        return CLIGitHubClient(
            locate: { gh }, environment: ["PATH": "/usr/bin:/bin", "GH_REPO": "other/repo"],
            directory: folder)
    }

    private var logged: [String] {
        get throws {
            String(decoding: try Data(contentsOf: log), as: UTF8.self)
                .split(separator: "\n").map(String.init)
        }
    }

    private let repo = GitHubRepo(host: "github.com", owner: "owner", name: "app")

    @Test func openPullRequestsAreListedForTheNamedRepoOutsideAnyCheckout() async throws {
        try script(
            output: """
                [{"number":3,"title":"t","url":"u","state":"OPEN","isDraft":false,
                "headRefName":"feature","headRefOid":"abc","headRepositoryOwner":{"login":"owner"},
                "baseRefName":"main","reviewDecision":null,"latestReviews":[],
                "statusCheckRollup":[],"updatedAt":"2026-10-23T12:00:00Z"}]
                """)
        let found = try await client().openPullRequests(in: repo)
        #expect(found.map(\.number) == [3])
        let lines = try logged
        #expect(
            lines.first
                == "pr list -R github.com/owner/app --state open --limit 100 --json "
                + GHPullRequest.summaryFields.joined(separator: ","))
        #expect(lines.dropFirst().first == "prompt=1 repo=unset")
        let real = try #require(realpath(folder.path, nil))
        defer { free(real) }
        #expect(lines.last == String(cString: real))
    }

    @Test func aBranchsLatestPullRequestIsAskedForByItsHead() async throws {
        try script()
        let found = try await client().latestPullRequest(from: "feat/a", in: repo)
        #expect(found == nil)
        #expect(
            try logged.first?.hasPrefix(
                "pr list -R github.com/owner/app --head feat/a --state all --limit 1 --json ")
                == true)
    }

    /// Checks and reviews cost a lot per PR, so only one PR's are read at a time.
    @Test func onePullRequestsChecksAndReviewsAreReadByNumber() async throws {
        try script(
            output: """
                {"number":3,"title":"t","url":"u","state":"OPEN","isDraft":false,
                "headRefName":"feature","headRefOid":"abc","headRepositoryOwner":{"login":"owner"},
                "baseRefName":"main","reviewDecision":null,"latestReviews":[{"state":"APPROVED"}],
                "statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],
                "updatedAt":"2026-10-23T12:00:00Z"}
                """)
        let found = try await client().pullRequest(3, in: repo)
        #expect(found.review == .approved)
        #expect(found.checks.failed == 1)
        #expect(
            try logged.first
                == "pr view 3 -R github.com/owner/app --json "
                + GHPullRequest.detailFields.joined(separator: ","))
        for slow in ["reviewDecision", "latestReviews", "statusCheckRollup"] {
            #expect(!GHPullRequest.summaryFields.contains(slow))
        }
    }

    @Test func hostsAreTheOnesGhHasAccountsFor() async throws {
        try script(
            output: #"{"hosts":{"github.com":[{"state":"success"}],"code.example.com":[]}}"#)
        #expect(try await client().hosts() == ["github.com"])
        #expect(try logged.first == "auth status --json hosts --no-refresh")
    }

    @Test func failuresSayWhatWentWrong() async throws {
        let cases: [(Int32, String, GitHubError)] = [
            (4, "To get started with GitHub CLI, please run:  gh auth login", .notSignedIn),
            (1, "GraphQL: API rate limit exceeded for user", .rateLimited),
            (1, "error connecting to api.github.com", .offline),
            (1, "could not resolve to a Repository", .failed("could not resolve to a Repository")),
        ]
        for (status, message, expected) in cases {
            try script(errors: message, status: status)
            await #expect(throws: expected) { try await client().openPullRequests(in: repo) }
        }
    }

    @Test func withoutGhNothingRuns() async {
        let client = CLIGitHubClient(locate: { nil })
        await #expect(throws: GitHubError.notInstalled) {
            try await client.openPullRequests(in: repo)
        }
    }
}
