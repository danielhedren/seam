import Foundation
import TestSupport
import Testing

@testable import SeamCore

/// SPEC §5.2 fixtures F1–F12, each built with real git.
@Suite struct BaseDetectionFixtureTests {
    private func detect(_ repo: FixtureRepo, _ worktree: URL) async throws -> BaseDetection {
        try await BaseDetector(git: repo.git).detect(in: worktree)
    }

    @Test func f1BranchOffMainPicksOriginMain() async throws {
        let repo = try await FixtureRepo()
        let fork = try await repo.sha("HEAD")
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "a", in: feature)
        try await repo.commit("b.txt", "b\n", "b", in: feature)

        let detection = try await detect(repo, feature)

        #expect(detection.branch == "feature")
        #expect(detection.parent?.name == "origin/main")
        #expect(detection.uniqueCommitCount == 2)
        #expect(detection.base == fork)
    }

    @Test func f2BranchThatMergedMainExcludesMainsChanges() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("feature.txt", "1\n", "feature 1", in: feature)
        let mainChange = try await repo.commit("main.txt", "main\n", "main moves")
        try await repo.run("push", "-q", "origin", "main")
        try await repo.run("merge", "-q", "--no-edit", "origin/main", in: feature)
        try await repo.commit("feature.txt", "1\n2\n", "feature 2", in: feature)

        let detection = try await detect(repo, feature)
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: feature, base: detection.base, scope: .all)

        #expect(detection.parent?.name == "origin/main")
        #expect(detection.base == mainChange)
        #expect(review.files.map(\.diff.path) == ["feature.txt"])
    }

    @Test func f3StackedBranchPicksItsParent() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "1\n", "b1", in: b)
        let bTip = try await repo.commit("b.txt", "1\n2\n", "b2", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)

        let detection = try await detect(repo, c)

        #expect(detection.parent?.name == "origin/b")
        #expect(detection.uniqueCommitCount == 1)
        #expect(detection.base == bTip)
        #expect(detection.candidates.contains { $0.name == "origin/main" && $0.commitCount == 3 })
    }

    @Test func f4ParentThatMergedMainAfterTheStackBranched() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        let b1 = try await repo.commit("b.txt", "1\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        try await repo.commit("main.txt", "main\n", "main moves")
        try await repo.run("push", "-q", "origin", "main")
        try await repo.run("merge", "-q", "--no-edit", "origin/main", in: b)
        try await repo.commit("b.txt", "1\n2\n", "b2", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)

        let detection = try await detect(repo, c)

        #expect(detection.parent?.name == "origin/b")
        #expect(detection.uniqueCommitCount == 1)
        #expect(detection.base == b1)
    }

    @Test func f5StackThatMergedANewerParent() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "1\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let b2 = try await repo.commit("b.txt", "1\n2\n", "b2", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        try await repo.run("merge", "-q", "--no-edit", "b", in: c)

        let detection = try await detect(repo, c)

        #expect(detection.parent?.name == "origin/b")
        #expect(detection.base == b2)
        #expect(detection.uniqueCommitCount == 2)
    }

    @Test func f6BranchStackedOnTopDoesNotHideCommits() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        let bTip = try await repo.commit("b.txt", "1\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let d = try await repo.worktree("d", branch: "d", from: "c")
        try await repo.commit("d.txt", "d\n", "d1", in: d)

        let detection = try await detect(repo, c)

        #expect(detection.parent?.name == "b")
        #expect(detection.base == bTip)
        #expect(detection.uniqueCommitCount == 1)
    }

    @Test func f7OwnPushedUpstreamIsNotAParent() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        let bTip = try await repo.commit("b.txt", "1\n", "b1", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        try await repo.run("push", "-q", "-u", "origin", "c", in: c)

        let detection = try await detect(repo, c)

        #expect(detection.parent?.name == "origin/b")
        #expect(detection.base == bTip)
    }

    @Test func f8FreshWorktreeDiffsOnlyUncommittedWork() async throws {
        let repo = try await FixtureRepo()
        let head = try await repo.sha("HEAD")
        let fresh = try await repo.worktree("fresh", branch: "fresh", from: "origin/main")
        try repo.write("new.txt", "new\n", in: fresh)

        let detection = try await detect(repo, fresh)
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: fresh, base: detection.base, scope: .all)

        #expect(detection.parent?.name == "origin/main")
        #expect(detection.uniqueCommitCount == 0)
        #expect(detection.base == head)
        #expect(review.files.map(\.diff.path) == ["new.txt"])
        #expect(review.files.first?.isUntracked == true)
    }

    @Test func f9DetachedHeadUsesTheSameAlgorithm() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        let bTip = try await repo.commit("b.txt", "1\n", "b1", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let path = repo.directory.resolved.appending(
            path: "wt-detached", directoryHint: .isDirectory)
        try await repo.run("worktree", "add", "-q", "--detach", path.path, "b")
        try await repo.commit("x.txt", "x\n", "detached work", in: path)

        let detection = try await detect(repo, path)

        #expect(detection.branch == nil)
        #expect(detection.parent?.name == "origin/b")
        #expect(detection.base == bTip)
    }

    @Test func f10SquashMergedParentFallsBackToMainOnceDeleted() async throws {
        let repo = try await FixtureRepo()
        let fork = try await repo.sha("HEAD")
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        let bTip = try await repo.commit("b.txt", "1\n", "b1", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        try await repo.commit("b.txt", "1\n", "squash of b")
        try await repo.run("push", "-q", "origin", "main")

        let whileParentExists = try await detect(repo, c)
        #expect(whileParentExists.parent?.name == "origin/b")
        #expect(whileParentExists.base == bTip)

        try await repo.run("worktree", "remove", b.path)
        try await repo.run("branch", "-q", "-D", "b")
        try await repo.run("push", "-q", "origin", "--delete", "b")
        try await repo.run("fetch", "-q", "--prune", "origin")

        let afterDeletion = try await detect(repo, c)
        #expect(afterDeletion.parent?.name == "origin/main")
        #expect(afterDeletion.base == fork)
        #expect(afterDeletion.uniqueCommitCount == 2)
    }

    @Test func f11UnpushedParentCommitsCountAsBase() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "1\n", "b1", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let unpushed = try await repo.commit("b.txt", "1\n2\n", "b2 (local only)", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)

        let detection = try await detect(repo, c)

        #expect(detection.parent?.name == "b")
        #expect(detection.base == unpushed)
        #expect(detection.uniqueCommitCount == 1)
    }

    @Test func f13DefaultBranchIsReviewedAgainstItsOwnRemote() async throws {
        let repo = try await FixtureRepo()
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        try await repo.commit("o.txt", "o\n", "o1", in: other)
        try await repo.run("push", "-q", "origin", "other", in: other)
        let stale = try await repo.sha("HEAD")
        try await repo.run("push", "-q", "origin", "other:main", in: other)
        try await repo.run("fetch", "-q", "origin")

        let detection = try await detect(repo, repo.main)

        #expect(detection.branch == "main")
        #expect(detection.parent?.name == "origin/main")
        #expect(detection.uniqueCommitCount == 0)
        #expect(detection.base == stale)
    }

    @Test func f14FreshWorktreeWhoseParentMovedOn() async throws {
        let repo = try await FixtureRepo()
        let fresh = try await repo.worktree("fresh", branch: "fresh", from: "origin/main")
        let head = try await repo.sha("HEAD")
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        try await repo.commit("main.txt", "m\n", "main moves")
        try await repo.run("push", "-q", "origin", "main")

        let detection = try await detect(repo, fresh)

        #expect(detection.parent?.name == "origin/main")
        #expect(detection.uniqueCommitCount == 0)
        #expect(detection.base == head)
    }

    @Test func aConfiguredDefaultBaseMayBeAShortName() async throws {
        let repo = try await FixtureRepo()
        try await repo.run("push", "-q", "origin", "main:develop")
        try await repo.run("fetch", "-q", "origin")
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/develop")
        try await repo.commit("f.txt", "f\n", "f1", in: feature)

        let detection = try await BaseDetector(
            git: repo.git, settings: DetectionSettings(defaultBase: "origin/develop")
        ).detect(in: feature)

        #expect(detection.candidates.contains { $0.isDefaultBase && $0.name == "origin/develop" })
    }

    @Test func f12FreshChildAtTheSameCommitIsNotAParent() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        let bTip = try await repo.commit("b.txt", "1\n", "b1", in: b)
        try await repo.run("push", "-q", "origin", "b", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        let cTip = try await repo.commit("c.txt", "c\n", "c1", in: c)
        let d = try await repo.worktree("d", branch: "d", from: "c")

        let forC = try await detect(repo, c)
        #expect(forC.parent?.name == "origin/b")
        #expect(forC.base == bTip)

        let forD = try await detect(repo, d)
        #expect(forD.parent?.name == "c")
        #expect(forD.base == cTip)
        #expect(forD.uniqueCommitCount == 0)
    }
}
