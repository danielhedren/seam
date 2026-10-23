import Foundation
import os

public enum GitHubError: Error, Equatable, Sendable {
    case notInstalled
    case notSignedIn
    case rateLimited
    case offline
    case failed(String)
    case cancelled
}

/// Reads pull requests (ADR 0005). Read methods only: there is no way to send gh an arbitrary
/// command, because `gh api -f` quietly turns a read into a write.
public protocol GitHubClient: Sendable {
    /// The hosts gh has an account for.
    func hosts() async throws(GitHubError) -> [String]
    /// The repo's open pull requests, without their reviews and checks.
    func openPullRequests(in repo: GitHubRepo) async throws(GitHubError) -> [PullRequest]
    /// The newest pull request from `branch` in any state, without its reviews and checks.
    func latestPullRequest(from branch: String, in repo: GitHubRepo) async throws(GitHubError)
        -> PullRequest?
    /// One pull request with its reviews and checks.
    func pullRequest(_ number: Int, in repo: GitHubRepo) async throws(GitHubError) -> PullRequest
    /// Every review thread of a pull request, with all their comments.
    func reviewThreads(_ number: Int, in repo: GitHubRepo) async throws(GitHubError)
        -> [GitHubReviewThread]
}

/// Runs the user's own `gh`. Every call names its repo with `-R` and runs outside any
/// repository with prompts off, so gh can't pick a remote itself, ask anything, or write its
/// choice into a repo's `.git/config`.
public struct CLIGitHubClient: GitHubClient {
    /// Finds `gh`; nil when it isn't installed. Called before every command, so it should cache.
    private let locate: @Sendable () async -> URL?
    private let environment: [String: String]
    private let directory: URL
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "GitKit")

    public init(
        locate: @escaping @Sendable () async -> URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.locate = locate
        var environment = environment
        for name in ["GH_REPO", "GH_HOST", "GH_FORCE_TTY", "CLICOLOR_FORCE"] {
            environment[name] = nil
        }
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_NO_EXTENSION_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        self.environment = environment
        self.directory = directory
    }

    public func hosts() async throws(GitHubError) -> [String] {
        struct Status: Decodable { var hosts: [String: [Account]] }
        struct Account: Decodable {}
        let output = try await run(["auth", "status", "--json", "hosts", "--no-refresh"])
        do {
            return try JSONDecoder().decode(Status.self, from: output).hosts
                .filter { !$0.value.isEmpty }.keys.sorted()
        } catch {
            throw .failed("unexpected gh auth status output")
        }
    }

    public func openPullRequests(in repo: GitHubRepo) async throws(GitHubError)
        -> [PullRequest]
    {
        try await pullRequests(repo, ["--state", "open", "--limit", "100"])
    }

    public func latestPullRequest(from branch: String, in repo: GitHubRepo)
        async throws(GitHubError) -> PullRequest?
    {
        try await pullRequests(repo, ["--head", branch, "--state", "all", "--limit", "1"]).first
    }

    public func pullRequest(_ number: Int, in repo: GitHubRepo) async throws(GitHubError)
        -> PullRequest
    {
        let output = try await run(
            ["pr", "view", String(number), "-R", repo.slug, "--json"]
                + [GHPullRequest.detailFields.joined(separator: ",")])
        do {
            return try GHPullRequest.decodeOne(output)
        } catch {
            logger.error("unreadable gh pr view output: \(error)")
            throw .failed("unexpected gh pr view output")
        }
    }

    public func reviewThreads(_ number: Int, in repo: GitHubRepo) async throws(GitHubError)
        -> [GitHubReviewThread]
    {
        var threads: [GitHubReviewThread] = []
        var after: String?
        repeat {
            var arguments = [
                "-F", "number=\(number)", "-f", "owner=\(repo.owner)", "-f", "name=\(repo.name)",
            ]
            if let after { arguments += ["-f", "after=\(after)"] }
            let answer = try await graphQL(
                ReviewThreadQuery.threads, arguments, on: repo.host,
                as: ReviewThreadQuery.ThreadsAnswer.self)
            guard let page = answer.data.repository?.pullRequest?.reviewThreads else {
                throw .failed("pull request #\(number) not found in \(repo.slug)")
            }
            for node in page.nodes {
                var thread = node.thread
                var comments = node.comments.pageInfo
                while comments.hasNextPage, let cursor = comments.endCursor {
                    let more = try await graphQL(
                        ReviewThreadQuery.moreComments,
                        ["-f", "id=\(node.id)", "-f", "after=\(cursor)"], on: repo.host,
                        as: ReviewThreadQuery.CommentsAnswer.self)
                    guard let page = more.data.node?.comments else { break }
                    thread.comments += page.nodes.map(\.comment)
                    comments = page.pageInfo
                }
                threads.append(thread)
            }
            after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
        } while after != nil
        return threads
    }

    /// Runs one of the fixed queries (ADR 0006); variables go as fields, never into the query.
    private func graphQL<Answer: Decodable>(
        _ query: String, _ variables: [String], on host: String, as type: Answer.Type
    ) async throws(GitHubError) -> Answer {
        let output = try await run(
            ["api", "graphql", "--hostname", host, "-f", "query=\(query)"] + variables)
        do {
            return try ReviewThreadQuery.decode(type, output)
        } catch {
            logger.error("unreadable gh api graphql output: \(error)")
            throw .failed("unexpected gh api graphql output")
        }
    }

    private func pullRequests(_ repo: GitHubRepo, _ filter: [String]) async throws(GitHubError)
        -> [PullRequest]
    {
        let output = try await run(
            ["pr", "list", "-R", repo.slug] + filter
                + ["--json", GHPullRequest.summaryFields.joined(separator: ",")])
        do {
            return try GHPullRequest.decode(output)
        } catch {
            logger.error("unreadable gh pr list output: \(error)")
            throw .failed("unexpected gh pr list output")
        }
    }

    private func run(_ arguments: [String]) async throws(GitHubError) -> Data {
        guard let executable = await locate() else { throw .notInstalled }
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: executable, arguments: arguments, directory: directory,
                environment: environment, input: nil)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .notInstalled
        }
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            logger.debug("gh \(arguments.prefix(2), privacy: .public) exited \(result.status)")
            throw Self.error(status: result.status, stderr: stderr)
        }
        return result.stdout
    }

    /// gh exits 4 when it needs a login, and 2 when cancelled; the rest is told by its message.
    static func error(status: Int32, stderr: String) -> GitHubError {
        let message = stderr.lowercased()
        if status == 4 || message.contains("gh auth login") { return .notSignedIn }
        if status == 2 { return .cancelled }
        if message.contains("rate limit") { return .rateLimited }
        let offline = [
            "dial tcp", "no such host", "could not resolve host", "connection refused",
            "network is unreachable", "i/o timeout", "error connecting to", "tls handshake",
        ]
        if offline.contains(where: message.contains) { return .offline }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
