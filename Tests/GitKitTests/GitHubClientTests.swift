import Foundation
import TestSupport
import Testing

@testable import GitKit

@Suite(.timeLimit(.minutes(1))) struct GitHubRepoTests {
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

@Suite(.timeLimit(.minutes(1))) struct PullRequestDecodingTests {
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

    @Test func ciShowsAsGitHubsCheckIcon() throws {
        func ci(_ checks: String) throws -> PullRequest.CI? {
            try decode(pullRequest(checks: checks)).first?.ci
        }
        let passed = #"{"status":"COMPLETED","conclusion":"SUCCESS"}"#
        let running = #"{"status":"IN_PROGRESS","conclusion":null}"#
        let failed = #"{"status":"COMPLETED","conclusion":"FAILURE"}"#
        #expect(try ci("[]") == nil)
        #expect(try ci("[\(passed)]") == .passed)
        #expect(try ci("[\(passed),\(running)]") == .running)
        #expect(try ci("[\(running),\(failed)]") == .failed)
    }

    @Test func aMergedPullRequestsFailedRunIsHistory() throws {
        let checks = #"[{"status":"COMPLETED","conclusion":"FAILURE"}]"#
        let read = try #require(try decode(pullRequest(state: "MERGED", checks: checks)).first)
        #expect(read.checks.failed == 1)
        #expect(read.ci == nil)
    }

    /// Ready to merge: open, not a draft, no check still running, and GitHub's merge button
    /// green, a failed optional check included.
    @Test(arguments: [
        (PullRequest.MergeState.clean, false, 0, true), (.unstable, false, 0, true),
        (.hasHooks, false, 0, true), (.blocked, false, 0, false), (.behind, false, 0, false),
        (.dirty, false, 0, false), (.clean, true, 0, false), (.clean, false, 1, false),
    ])
    func readyToMergeFollowsGitHubsMergeState(
        state: PullRequest.MergeState, draft: Bool, pending: Int, ready: Bool
    ) throws {
        var pullRequest = try #require(try decode(pullRequest(draft: draft)).first)
        pullRequest.mergeState = state
        pullRequest.checks.pending = pending
        #expect(pullRequest.isReadyToMerge == ready)
    }
}

/// The real client against a stand-in `gh` that records how it was run.
@Suite(.timeLimit(.minutes(1))) struct CLIGitHubClientTests {
    private let folder: URL
    private let gh: URL
    private let log: URL

    init() throws {
        folder = Scratch.path("seam-gh")
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
                "mergeStateStatus":"BLOCKED","updatedAt":"2026-10-23T12:00:00Z"}
                """)
        let found = try await client().pullRequest(3, in: repo)
        #expect(found.review == .approved)
        #expect(found.checks.failed == 1)
        #expect(found.mergeState == .blocked)
        #expect(
            try logged.first
                == "pr view 3 -R github.com/owner/app --json "
                + GHPullRequest.detailFields.joined(separator: ","))
        for slow in ["reviewDecision", "latestReviews", "statusCheckRollup"] {
            #expect(!GHPullRequest.summaryFields.contains(slow))
        }
    }

    private static func threadsPage(_ ids: [String], next: String?) -> String {
        let nodes = ids.map { id in
            """
            {"id":"\(id)","isResolved":false,"path":"a.txt","diffSide":"RIGHT","originalLine":3,
             "originalStartLine":null,"subjectType":"LINE",
             "comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
               {"databaseId":7,"author":{"login":"octocat"},"body":"Why?",
                "createdAt":"2026-10-23T12:00:00Z","url":"u","diffHunk":"@@ -1,2 +1,3 @@"}]}}
            """
        }
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return """
            {"data":{"repository":{"pullRequest":{"reviewThreads":{
              "pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(cursor)},
              "nodes":[\(nodes.joined(separator: ","))]}}}}}
            """
    }

    /// Two pages: the second is asked for with the first's cursor, and both are kept.
    @Test func reviewThreadsAreReadPageByPageWithTheFixedQuery() async throws {
        let first = Self.threadsPage(["T1"], next: "C1")
        let second = Self.threadsPage(["T2"], next: nil)
        let text = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(log.path)'
            case "$*" in
            *after=C1*) cat <<'SEAM_EOF'
            \(second)
            SEAM_EOF
            ;;
            *) cat <<'SEAM_EOF'
            \(first)
            SEAM_EOF
            ;;
            esac
            """
        try Data(text.utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        let threads = try await client().discussion(12, in: repo).threads

        #expect(threads.map(\.id) == ["T1", "T2"])
        #expect(threads.first?.lines == 3...3)
        #expect(threads.first?.comments.first?.author == "octocat")
        // The query spans lines, so the log is read whole.
        let log = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        #expect(
            log.components(separatedBy: "api graphql --hostname github.com -f query=").count == 3)
        #expect(log.contains("-F number=12 -f owner=owner -f name=app\n"))
        #expect(log.contains("-F number=12 -f owner=owner -f name=app -f after=C1\n"))
    }

    /// The conversation and the viewer come with the first page only; later pages are threads.
    @Test func theFirstPageAlsoReadsTheConversationAndWhoGhReadsAs() async throws {
        let first = Self.threadsPage(["T1"], next: "C1")
        let second = Self.threadsPage(["T2"], next: nil)
        let text = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(log.path)'
            case "$*" in
            *after=C1*) cat <<'SEAM_EOF'
            \(second)
            SEAM_EOF
            ;;
            *) cat <<'SEAM_EOF'
            \(first)
            SEAM_EOF
            ;;
            esac
            """
        try Data(text.utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)

        _ = try await client().discussion(12, in: repo)

        let calls = String(decoding: try Data(contentsOf: log), as: UTF8.self)
            .components(separatedBy: "api graphql --hostname github.com -f query=").dropFirst()
        #expect(calls.count == 2)
        #expect(calls.first?.contains("viewer { login }") == true)
        #expect(calls.first?.contains("reviews(last: 100)") == true)
        #expect(calls.last?.contains("viewer") == false)
        #expect(calls.last?.contains("reviews(") == false)
    }

    /// Reviews say what they decided; a plain "commented" one without words only wraps line
    /// comments, which are threads, and a pending one is only its author's.
    @Test func theConversationIsCommentsAndReviewVerdictsOldestFirst() throws {
        let json = """
            {"data":{"viewer":{"login":"me"},"repository":{"pullRequest":{
              "comments":{"nodes":[
                {"databaseId":5,"author":{"login":"octocat"},"body":"Looks close.",
                 "createdAt":"2026-10-23T12:00:00Z","url":"c5"},
                {"databaseId":null,"author":{"login":"octocat"},"body":"Imported.",
                 "createdAt":"2026-10-23T12:30:00Z","url":"c?"}]},
              "reviews":{"nodes":[
                {"databaseId":9,"author":{"login":"hubot"},"body":"","state":"APPROVED",
                 "submittedAt":"2026-10-23T13:00:00Z","url":"r9"},
                {"databaseId":8,"author":{"login":"hubot"},"body":"Fix the name.",
                 "state":"CHANGES_REQUESTED","submittedAt":"2026-10-23T11:00:00Z","url":"r8"},
                {"databaseId":7,"author":{"login":"hubot"},"body":"","state":"COMMENTED",
                 "submittedAt":"2026-10-23T10:00:00Z","url":"r7"},
                {"databaseId":6,"author":{"login":"me"},"body":"","state":"PENDING",
                 "submittedAt":null,"url":"r6"}]},
              "reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}
            """
        let answer = try ReviewThreadQuery.decode(
            ReviewThreadQuery.ThreadsAnswer.self, Data(json.utf8))
        let items = try #require(answer.data.repository?.pullRequest).conversation
        #expect(answer.data.viewer?.login == "me")
        #expect(items.map(\.id) == [8, 5, 9])
        #expect(items.map(\.kind) == [.changesRequested, .comment, .approved])
        #expect(items.first?.body == "Fix the name.")
    }

    /// ADR 0006: the queries gh runs can read, never write.
    @Test func theFixedQueriesHaveNoMutation() {
        for query in [
            ReviewThreadQuery.firstThreads, ReviewThreadQuery.threads,
            ReviewThreadQuery.moreComments,
        ] {
            #expect(!query.lowercased().contains("mutation"))
            #expect(query.hasPrefix("query("))
        }
    }

    /// GitHub lets a range start on removed lines and end on added ones; Seam's anchor has one
    /// side, so it keeps the end line, where GitHub shows the comment.
    @Test func aRangeAcrossBothSidesIsAnchoredOnItsLastLine() throws {
        let json = """
            {"data":{"repository":{"pullRequest":{"reviewThreads":{
              "pageInfo":{"hasNextPage":false,"endCursor":null},
              "nodes":[{"id":"T","isResolved":false,"path":"a.txt","diffSide":"RIGHT",
                "startDiffSide":"LEFT","originalLine":12,"originalStartLine":10,
                "subjectType":"LINE",
                "comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}]}}}}}
            """
        let answer = try ReviewThreadQuery.decode(
            ReviewThreadQuery.ThreadsAnswer.self, Data(json.utf8))
        let thread = try #require(answer.data.repository?.pullRequest?.reviewThreads.nodes.first)
        #expect(thread.thread.lines == 12...12)
        #expect(thread.thread.side == .right)
        #expect(ReviewThreadQuery.threads.contains("startDiffSide"))
    }

    @Test func aFileCommentHasNoLinesAndAGoneAccountIsGhost() throws {
        let json = """
            {"data":{"repository":{"pullRequest":{"reviewThreads":{
              "pageInfo":{"hasNextPage":false,"endCursor":null},
              "nodes":[{"id":"T","isResolved":true,"path":"a.txt","diffSide":"LEFT",
                "originalLine":5,"originalStartLine":2,"subjectType":"FILE",
                "comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"databaseId":1,"author":null,"body":"b","createdAt":"2026-10-23T12:00:00Z",
                   "url":"u","diffHunk":null}]}},
               {"id":"R","isResolved":false,"path":"b.txt","diffSide":"LEFT",
                "originalLine":5,"originalStartLine":2,"subjectType":"LINE",
                "comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}]}}}}}
            """
        let answer = try ReviewThreadQuery.decode(
            ReviewThreadQuery.ThreadsAnswer.self, Data(json.utf8))
        let threads = try #require(answer.data.repository?.pullRequest?.reviewThreads.nodes)
            .map(\.thread)
        #expect(threads[0].lines == nil)
        #expect(threads[0].isFileComment)
        #expect(threads[0].isResolved)
        #expect(threads[0].comments.first?.author == "ghost")
        #expect(threads[1].lines == 2...5)
        #expect(threads[1].side == .left)
        #expect(!threads[1].isFileComment)
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
