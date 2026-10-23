import Foundation
import GitKit

/// Where a repo's pull requests live on GitHub, and what each local branch is called there
/// (SPEC §7.8).
public struct PullRequestTargets: Equatable, Sendable {
    /// A local branch as GitHub knows it: its upstream's name, and the owner of the remote it
    /// pushes to when that's known, which tells a fork's PR from the main repo's.
    public struct Head: Equatable, Sendable {
        public var name: String
        public var owner: String?
    }

    public var repo: GitHubRepo
    /// The git remote of `repo`.
    public var remote: String
    var heads: [String: Head] = [:]

    /// The remotes that point at GitHub, by name.
    public static func remotes(in directory: URL, refs: RefSnapshot, git: any GitClient) async
        -> [String: GitHubRepo]
    {
        var repos: [String: GitHubRepo] = [:]
        for remote in refs.remotes {
            // `--get-url` applies `insteadOf` and doesn't touch the network.
            guard
                let url = try? await git.optionalLine(
                    ["ls-remote", "--get-url", remote], in: directory),
                let repo = GitHubRepo.parse(url)
            else { continue }
            repos[remote] = repo
        }
        return repos
    }

    /// Hosts Seam treats as GitHub without asking gh.
    public static func isKnownHost(_ host: String) -> Bool {
        host == "github.com" || host.hasSuffix(".ghe.com")
    }

    /// PRs are opened against `upstream` when a fork has one, else `origin`, else the first
    /// GitHub remote. Nil without any remote on a host in `hosts`.
    public init?(remotes: [String: GitHubRepo], hosts: Set<String>, refs: RefSnapshot) {
        let usable = remotes.filter { hosts.contains($0.value.host) }
        guard
            let remote = ["upstream", "origin"].first(where: { usable[$0] != nil })
                ?? usable.keys.sorted().first,
            let repo = usable[remote]
        else { return nil }
        self.repo = repo
        self.remote = remote
        for (ref, row) in refs.refs where ref.hasPrefix(RefName.heads) {
            let branch = String(ref.dropFirst(RefName.heads.count))
            heads[branch] = Self.head(
                of: branch, upstream: row.upstream, remotes: usable, refs: refs)
        }
    }

    /// A branch tracking `refs/remotes/<remote>/<name>` is `<name>` there. One tracking nothing,
    /// or the default branch it was cut from (`worktree add -b x origin/main`), pushes under its
    /// own name; taking `main` for its name would match every PR opened from main.
    private static func head(
        of branch: String, upstream: String, remotes: [String: GitHubRepo], refs: RefSnapshot
    ) -> Head {
        guard upstream.hasPrefix(RefName.remotes) else { return Head(name: branch, owner: nil) }
        let path = upstream.dropFirst(RefName.remotes.count)
        for (remote, repo) in remotes where path.hasPrefix(remote + "/") {
            let name = String(path.dropFirst(remote.count + 1))
            guard name == branch || name != refs.defaultBranch(of: remote) else { break }
            return Head(name: name, owner: repo.owner)
        }
        return Head(name: branch, owner: nil)
    }

    public func head(of branch: String) -> Head {
        heads[branch] ?? Head(name: branch, owner: nil)
    }

    /// The branch's PR among `pullRequests`: from its owner when known, open before merged
    /// before closed, then the most recently updated.
    public func pullRequest(for branch: String, in pullRequests: [PullRequest]) -> PullRequest? {
        let head = head(of: branch)
        let rank: [PullRequest.State: Int] = [.open: 0, .merged: 1, .closed: 2]
        return pullRequests.filter {
            $0.head == head.name && (head.owner == nil || $0.headOwner == head.owner)
        }
        .min { lhs, rhs in
            let (left, right) = (rank[lhs.state] ?? 3, rank[rhs.state] ?? 3)
            return left == right ? lhs.updated > rhs.updated : left < right
        }
    }

    /// The local ref for the branch a PR merges into: the PR repo's remote copy, origin's, or a
    /// local branch. Nil when none of them exists here; Seam never fetches.
    public func baseRef(of pullRequest: PullRequest, refs: RefSnapshot) -> String? {
        let base = pullRequest.base
        return [
            RefName.remotes + remote + "/" + base, RefName.remotes + "origin/" + base,
            RefName.heads + base,
        ].first { refs.refs[$0] != nil }
    }
}

extension RefSnapshot {
    /// A local branch's tip.
    public func tip(of branch: String) -> String? {
        refs[RefName.heads + branch]?.tip
    }

    /// The branch `<remote>/HEAD` points at: `main` for `refs/remotes/origin/main`.
    public func defaultBranch(of remote: String) -> String? {
        let prefix = RefName.remotes + remote + "/"
        guard let target = symbolic[prefix + "HEAD"], target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }
}

extension PullRequest {
    /// Commits on the local branch the PR doesn't have yet; nil when they're the same commit or
    /// the PR's head isn't here to count from.
    public static func unpushedCount(
        of branch: String, headCommit: String, in directory: URL, git: any GitClient
    ) async -> Int? {
        guard
            let line = try? await git.optionalLine(
                ["rev-list", "--count", headCommit + "..refs/heads/" + branch], in: directory),
            let count = Int(line), count > 0
        else { return nil }
        return count
    }
}
