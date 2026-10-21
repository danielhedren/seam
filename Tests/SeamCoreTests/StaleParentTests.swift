import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

@Suite struct StaleParentTests {
    private func check(_ repo: FixtureRepo, _ worktree: URL) async throws -> StaleParent? {
        let detection = try await BaseDetector(git: repo.git).detect(in: worktree)
        return try await StaleParent.check(detection, in: worktree, git: repo.git)
    }

    @Test func aLiveParentIsNotStale() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        try await repo.run("push", "-q", "-u", "origin", "b", in: b)
        try await repo.commit("b.txt", "b\nmore\n", "b2 (local)", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)

        #expect(try await check(repo, c) == nil)
    }

    @Test func aParentWhoseUpstreamIsGoneLooksMerged() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        try await repo.run("push", "-q", "-u", "origin", "b", in: b)
        try await repo.commit("b.txt", "b\nmore\n", "b2 (local)", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        try await repo.run("push", "-q", "origin", "--delete", "b")
        try await repo.run("fetch", "-q", "--prune", "origin")

        let stale = try await check(repo, c)

        #expect(stale?.parent == "b")
        #expect(stale?.reason == .upstreamGone)
        #expect(stale?.suggestion.name == "origin/main")
    }

    @Test func aLocalOnlyParentAlreadyInMainLooksMerged() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        try await repo.run("merge", "-q", "--no-ff", "--no-edit", "b")
        try await repo.commit("main.txt", "m\n", "main moves")
        try await repo.run("push", "-q", "origin", "main")

        let stale = try await check(repo, c)

        #expect(stale?.parent == "b")
        #expect(stale?.reason == .containedIn)
        #expect(stale?.suggestion.name == "origin/main")
    }

    @Test func aRemoteParentIsNeverFlagged() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)

        #expect(try await check(repo, c) == nil)
    }
}
