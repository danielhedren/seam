import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct PullRequestTargetTests {
    private static let github: Set<String> = ["github.com"]

    private func pullRequest(
        _ number: Int, head: String, owner: String = "owner", state: PullRequest.State = .open,
        base: String = "main", updated: TimeInterval = 0
    ) -> PullRequest {
        PullRequest(
            number: number, title: "PR \(number)",
            url: "https://github.com/owner/app/pull/\(number)",
            state: state, head: head, headOwner: owner, headCommit: "abc", base: base,
            updated: Date(timeIntervalSince1970: updated))
    }

    private func targets(_ repo: FixtureRepo, hosts: Set<String> = github) async throws
        -> (PullRequestTargets?, RefSnapshot)
    {
        let refs = try await RefSnapshot.load(in: repo.main, git: repo.git)
        let remotes = await PullRequestTargets.remotes(in: repo.main, refs: refs, git: repo.git)
        return (PullRequestTargets(remotes: remotes, hosts: hosts, refs: refs), refs)
    }

    @Test func originOnGitHubIsWherePullRequestsLive() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("remote", "set-url", "origin", "git@github.com:owner/app.git")
        let (found, _) = try await targets(repo)
        let targets = try #require(found)
        #expect(targets.repo.slug == "github.com/owner/app")
        #expect(targets.remote == "origin")
    }

    @Test func aLocalRemoteOrAnUnknownHostIsNotGitHub() async throws {
        let repo = try await FixtureRepo()
        #expect(try await targets(repo).0 == nil)
        try await repo.run("remote", "set-url", "origin", "https://code.example.com/owner/app.git")
        #expect(try await targets(repo).0 == nil)
        #expect(try await targets(repo, hosts: ["code.example.com"]).0 != nil)
    }

    /// `insteadOf` turns a short name into the real URL, as git itself would fetch it.
    @Test func remoteURLsAreReadTheWayGitRewritesThem() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("config", "url.https://github.com/.insteadOf", "gh:")
        try await repo.run("remote", "set-url", "origin", "gh:owner/app.git")
        #expect(try await targets(repo).0?.repo.slug == "github.com/owner/app")
    }

    /// A fork pushes to `origin` and opens its PRs on `upstream`.
    @Test func aForksPullRequestsLiveUpstreamAndItsBranchesComeFromItsOwner() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("remote", "set-url", "origin", "https://github.com/me/app.git")
        try await repo.run("remote", "add", "upstream", "https://github.com/owner/app.git")
        try await repo.run("branch", "feature")
        try await repo.run("config", "branch.feature.remote", "origin")
        try await repo.run("config", "branch.feature.merge", "refs/heads/feature")
        try await repo.run("update-ref", "refs/remotes/origin/feature", "HEAD")
        let targets = try #require(try await targets(repo).0)
        #expect(targets.repo.slug == "github.com/owner/app")
        #expect(targets.head(of: "feature") == .init(name: "feature", owner: "me"))

        let theirs = pullRequest(1, head: "feature", owner: "someone", updated: 2)
        let mine = pullRequest(2, head: "feature", owner: "me", updated: 1)
        #expect(targets.pullRequest(for: "feature", in: [theirs, mine]) == mine)
    }

    /// `git worktree add -b feature origin/main` tracks main until the branch is pushed.
    @Test func aBranchStillTrackingTheDefaultBranchIsKnownByItsOwnName() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        try await repo.run("branch", "--track", "feature", "origin/main")
        let targets = try #require(try await targets(repo).0)
        #expect(targets.head(of: "feature") == .init(name: "feature", owner: nil))
        let fromMain = pullRequest(5, head: "main", state: .closed)
        #expect(targets.pullRequest(for: "feature", in: [fromMain]) == nil)
    }

    @Test func aBranchsOpenPullRequestWinsOverOlderMergedOnes() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        let targets = try #require(try await targets(repo).0)
        let merged = pullRequest(1, head: "feature", state: .merged, updated: 3)
        let open = pullRequest(2, head: "feature", updated: 1)
        let newerClosed = pullRequest(3, head: "feature", state: .closed, updated: 4)
        #expect(targets.pullRequest(for: "feature", in: [merged, newerClosed, open]) == open)
        #expect(targets.pullRequest(for: "feature", in: [merged, newerClosed]) == merged)
        #expect(targets.pullRequest(for: "other", in: [open]) == nil)
    }

    @Test func aPullRequestsBaseIsTheLocalRefForItsBranch() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("remote", "set-url", "origin", "https://github.com/owner/app.git")
        try await repo.run("branch", "local-only")
        let (found, refs) = try await targets(repo)
        let targets = try #require(found)
        #expect(
            targets.baseRef(of: pullRequest(1, head: "x"), refs: refs) == "refs/remotes/origin/main"
        )
        #expect(
            targets.baseRef(of: pullRequest(1, head: "x", base: "local-only"), refs: refs)
                == "refs/heads/local-only")
        #expect(
            targets.baseRef(of: pullRequest(1, head: "x", base: "unfetched"), refs: refs) == nil)
        #expect(refs.defaultBranch(of: "origin") == "main")
    }

    @Test func commitsNotInThePullRequestAreCounted() async throws {
        let repo = try await FixtureRepo()
        let pushed = try await repo.sha("HEAD")
        try await repo.commit("a.txt", "a\n", "not pushed")
        try await repo.commit("a.txt", "b\n", "nor this")
        #expect(
            await PullRequest.unpushedCount(
                of: "main", headCommit: pushed, in: repo.main, git: repo.git) == 2)
        #expect(
            await PullRequest.unpushedCount(
                of: "main", headCommit: try await repo.sha("HEAD"), in: repo.main, git: repo.git)
                == nil)
        #expect(
            await PullRequest.unpushedCount(
                of: "main", headCommit: String(repeating: "0", count: 40), in: repo.main,
                git: repo.git) == nil)
    }

    @Test func aLocalParentWhosePullRequestMergedIsStale() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let detection = try await BaseDetector(git: repo.git).detect(in: c)
        #expect(try await StaleParent.check(detection, in: c, git: repo.git) == nil)

        let stale = StaleParent.pullRequestMerged(detection, number: 7)
        #expect(stale?.parent == "b")
        #expect(stale?.reason == .pullRequestMerged(7))
        #expect(stale?.suggestion.name == "origin/main")
    }
}
