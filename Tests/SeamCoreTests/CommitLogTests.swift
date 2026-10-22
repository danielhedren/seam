import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

@Suite struct CommitLogTests {
    @Test func listsTheBranchsCommitsNewestFirstAboveItsBase() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        let first = try await repo.commit("a.txt", "a\n", "add a")
        let second = try await repo.commit("b.txt", "b\n", "add b: with | odd chars")

        let log = try await CommitLog.load(base: base, in: repo.main, git: repo.git)

        #expect(log.commits.map(\.id) == [second, first])
        #expect(log.commits.map(\.subject) == ["add b: with | odd chars", "add a"])
        #expect(log.base.id == base)
        #expect(log.base.subject == "initial")
        #expect(!log.isTruncated)
    }

    @Test func aMergeFromMainIsOneEntry() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("f", branch: "f", from: "main")
        let base = try await repo.sha("HEAD")
        try await repo.commit("f.txt", "f\n", "feature", in: feature)
        try await repo.commit("m.txt", "m\n", "on main")
        try await repo.run("merge", "-q", "--no-edit", "main", in: feature)

        let log = try await CommitLog.load(base: base, in: feature, git: repo.git)

        #expect(log.commits.map(\.subject).count == 2)
        #expect(log.commits.last?.subject == "feature")
    }

    private let log = CommitLog(
        commits: ["c", "b", "a"].map {
            ReviewCommit(id: $0, shortID: $0, subject: $0, date: .distantPast)
        },
        base: ReviewCommit(id: "base", shortID: "base", subject: "", date: .distantPast))

    @Test func scopesAreRunsOfRows() {
        #expect(
            log.selection(for: .all) == CommitSelection(newest: .workingTree, oldest: .commit("a")))
        #expect(
            log.selection(for: .committed)
                == CommitSelection(newest: .commit("c"), oldest: .commit("a")))
        #expect(
            log.selection(for: .uncommitted)
                == CommitSelection(newest: .workingTree, oldest: .workingTree))
        #expect(
            log.scope(matching: CommitSelection(newest: .commit("c"), oldest: .commit("a")))
                == .committed)
        #expect(
            log.scope(matching: CommitSelection(newest: .commit("c"), oldest: .commit("b"))) == nil)
    }

    @Test func pickedRowsSpanOneRun() {
        #expect(
            log.selection(spanning: [.commit("a"), .commit("c")], showsWorkingTree: true)
                == CommitSelection(newest: .commit("c"), oldest: .commit("a")))
        #expect(
            log.selection(spanning: [.commit("b")], showsWorkingTree: false)
                == CommitSelection(newest: .commit("b"), oldest: .commit("b")))
        #expect(log.selection(spanning: [], showsWorkingTree: true) == nil)
    }

    @Test func everyCommitWithNothingUncommittedIsAll() {
        #expect(
            log.selection(spanning: [.commit("c"), .commit("a")], showsWorkingTree: false)
                == log.selection(for: .all))
    }

    @Test func aSelectionDiffsFromItsOldestCommitsParent() throws {
        let latest = try #require(
            log.range(for: CommitSelection(newest: .commit("c"), oldest: .commit("c"))))
        #expect(latest.base == "c^" && latest.head == "c" && latest.scope == .committed)
        let withWorkingTree = try #require(
            log.range(for: CommitSelection(newest: .workingTree, oldest: .commit("b"))))
        #expect(withWorkingTree.base == "b^" && withWorkingTree.scope == .all)
        #expect(
            log.range(for: CommitSelection(newest: .commit("gone"), oldest: .commit("a"))) == nil)
        #expect(log.range(for: CommitSelection(newest: .commit("a"), oldest: .commit("c"))) == nil)
    }
}
