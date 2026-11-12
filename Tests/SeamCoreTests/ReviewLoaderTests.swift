import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

/// A review without a working tree, such as a pull request's, ends at a commit (SPEC §6.4).
@Suite(.timeLimit(.minutes(1))) struct ReviewLoaderTests {
    @Test func aHeadCommitsReviewIsItsCommitsWithoutTheWorkingTree() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        let first = try await repo.commit("a.txt", "a\n", "add a")
        let head = try await repo.commit("b.txt", "b\n", "add b")
        try await repo.commit("c.txt", "c\n", "after the head")
        try repo.write("d.txt", "uncommitted\n")
        let loader = ReviewLoader(git: repo.git, fileSystem: LocalFileSystem())

        let log = try await loader.commits(from: base, to: head, in: repo.main)
        let all = try await loader.diff(
            log, from: base, to: head, in: repo.main, selection: nil, scope: .all,
            options: DiffOptions())
        let latest = try await loader.diff(
            log, from: base, to: head, in: repo.main,
            selection: CommitSelection(newest: .commit(head), oldest: .commit(head)),
            scope: .all, options: DiffOptions())
        let throughTheTop = try await loader.diff(
            log, from: base, to: head, in: repo.main,
            selection: CommitSelection(newest: .workingTree, oldest: .commit(first)),
            scope: .all, options: DiffOptions())

        #expect(log.commits.map(\.id) == [head, first])
        #expect(all.diff.files.map(\.diff.path) == ["a.txt", "b.txt"])
        #expect(all.diff.scope == .committed)
        #expect(latest.diff.files.map(\.diff.path) == ["b.txt"])
        #expect(throughTheTop.diff.files.map(\.diff.path) == ["a.txt", "b.txt"])
    }

    /// Nothing on disk belongs to the head: its own `.gitattributes` and `.editorconfig` apply.
    @Test func aHeadCommitsAttributesAndEditorConfigComeFromItsTree() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try await repo.commit(".gitattributes", "gen.txt linguist-generated\n", "attributes")
        try await repo.commit(".editorconfig", "[*]\ntab_width = 8\n", "editorconfig")
        let head = try await repo.commit("gen.txt", "g\n", "generated")
        try repo.write(".gitattributes", "")
        try repo.write(".editorconfig", "[*]\ntab_width = 2\n")
        let loader = ReviewLoader(git: repo.git, fileSystem: LocalFileSystem())

        let log = try await loader.commits(from: base, to: head, in: repo.main)
        let review = try await loader.diff(
            log, from: base, to: head, in: repo.main, selection: nil, scope: .all,
            options: DiffOptions())
        let config = await loader.editorConfig(in: repo.main, at: head)

        #expect(review.diff.files.filter(\.isGenerated).map(\.diff.path) == ["gen.txt"])
        #expect(config?.tabWidth(for: "a.txt") == 8)
    }
}
