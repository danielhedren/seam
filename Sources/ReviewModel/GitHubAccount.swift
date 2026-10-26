import Foundation
import GitKit
import Observation
import SeamCore

/// `gh` as the whole app sees it (SPEC §7.8): which hosts it has accounts for, and how its last
/// call went, which Settings shows. Shared by every window.
@MainActor
@Observable
public final class GitHubAccount {
    package enum Status: Equatable {
        case unknown
        case ready
        case failed(GitHubError)
    }

    let client: any GitHubClient
    package private(set) var status = Status.unknown
    /// Bumped by Settings › Check Again; every window refreshes when it changes.
    package private(set) var retries = 0
    private var accountHosts: Set<String>?
    @ObservationIgnored private let onRetry: @Sendable () async -> Void

    init(client: any GitHubClient, onRetry: @escaping @Sendable () async -> Void = {}) {
        self.client = client
        self.onRetry = onRetry
    }

    /// Never runs anything: the default for tests and previews.
    public static func none() -> GitHubAccount {
        GitHubAccount(client: NoGitHub())
    }

    /// The user's own gh, found through their login shell's PATH like the editor command.
    public static func live() -> GitHubAccount {
        let locator = GHLocator()
        return GitHubAccount(
            client: CLIGitHubClient(locate: { await locator.locate() }),
            onRetry: { await locator.reset() })
    }

    /// Which of `hosts` are GitHub: github.com and GHE.com always, any other only when gh has an
    /// account there. gh is asked once; a failed answer isn't kept, so the next read asks again.
    func gitHubHosts(among hosts: Set<String>) async throws(GitHubError) -> Set<String> {
        let known = hosts.filter(PullRequestTargets.isKnownHost)
        guard known.count < hosts.count else { return known }
        if accountHosts == nil {
            accountHosts = Set(try await client.hosts())
        }
        return known.union(hosts.intersection(accountHosts ?? []))
    }

    package func note(_ error: GitHubError?) {
        status = error.map(Status.failed) ?? .ready
    }

    package func checkAgain() {
        accountHosts = nil
        status = .unknown
        Task {
            await onRetry()
            retries += 1
        }
    }
}

/// Finds `gh` once: the login shell's PATH, then Homebrew's usual places.
package actor GHLocator {
    private var found: URL??
    private let path = LoginShellPath()

    func locate() async -> URL? {
        if let found { return found }
        let shell = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        let directories =
            await path.value(shell: shell).split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        let gh = directories.map { URL(fileURLWithPath: $0).appending(path: "gh") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        found = .some(gh)
        return gh
    }

    func reset() {
        found = nil
    }
}

package struct NoGitHub: GitHubClient {
    package func hosts() throws(GitHubError) -> [String] { throw .notInstalled }

    package func openPullRequests(in repo: GitHubRepo) throws(GitHubError) -> [PullRequest] {
        throw .notInstalled
    }

    package func latestPullRequest(from branch: String, in repo: GitHubRepo) throws(GitHubError)
        -> PullRequest?
    {
        throw .notInstalled
    }

    package func pullRequest(_ number: Int, in repo: GitHubRepo) throws(GitHubError) -> PullRequest
    {
        throw .notInstalled
    }

    package func reviewThreads(_ number: Int, in repo: GitHubRepo) throws(GitHubError)
        -> [GitHubReviewThread]
    {
        throw .notInstalled
    }
}
