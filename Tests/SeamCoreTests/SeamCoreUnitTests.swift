import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

@Suite struct CandidateRankingTests {
    private func candidate(
        _ ref: String, count: Int, configure: (inout ParentCandidate) -> Void = { _ in }
    )
        -> ParentCandidate
    {
        var item = ParentCandidate(ref: ref, tip: ref, commitCount: count)
        configure(&item)
        return item
    }

    @Test func fewerCommitsWinsOverEveryTieBreak() {
        let ranked = ParentCandidate.ranked([
            candidate("refs/remotes/origin/main", count: 17) {
                $0.isDefaultBase = true
                $0.tipIsBoundary = true
            },
            candidate("refs/heads/parent", count: 5),
        ])
        #expect(ranked.map(\.name) == ["parent", "origin/main"])
    }

    @Test func tieBreaksApplyInSpecOrder() {
        let boundary = candidate("refs/heads/z-boundary", count: 1) { $0.tipIsBoundary = true }
        let upstream = candidate("refs/heads/y-upstream", count: 1) { $0.isUpstream = true }
        let defaultBase = candidate("refs/heads/x-default", count: 1) { $0.isDefaultBase = true }
        let remote = candidate("refs/remotes/origin/w-remote", count: 1)
        let recent = candidate("refs/heads/v-recent", count: 1) { $0.committerDate = 10 }
        let older = candidate("refs/heads/u-older", count: 1)

        let ranked = ParentCandidate.ranked([
            older, recent, remote, defaultBase, upstream, boundary,
        ])

        #expect(
            ranked.map(\.name) == [
                "z-boundary", "y-upstream", "x-default", "origin/w-remote", "v-recent", "u-older",
            ])
    }
}

@Suite struct GlobTests {
    @Test(arguments: [
        ("origin/renovate/**", "origin/renovate/npm/x", true),
        ("origin/renovate/**", "origin/renovate-x", false),
        ("**/Generated/**", "src/A/Generated/B.cs", true),
        ("**/Generated/**", "Generated/B.cs", true),
        ("**/*.g.cs", "a/b/c.g.cs", true),
        ("*.lock", "dir/x.lock", false),
        ("feat/?", "feat/a", true),
        ("feat/?", "feat/ab", false),
    ])
    func matches(pattern: String, path: String, expected: Bool) {
        #expect(Glob(pattern).matches(path) == expected)
    }
}

@Suite struct ReviewDiffTests {
    @Test func scopesSplitCommittedFromUncommittedWork() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try await repo.commit("committed.txt", "c\n", "commit")
        try repo.write("README.md", "fixture\nedited\n")
        try repo.write("untracked.txt", "u\n")
        let builder = ReviewDiffBuilder(git: repo.git)

        let all = try await builder.build(worktree: repo.main, base: base, scope: .all)
        let committed = try await builder.build(worktree: repo.main, base: base, scope: .committed)
        let uncommitted = try await builder.build(
            worktree: repo.main, base: base, scope: .uncommitted)

        #expect(all.files.map(\.diff.path) == ["README.md", "committed.txt", "untracked.txt"])
        #expect(committed.files.map(\.diff.path) == ["committed.txt"])
        #expect(uncommitted.files.map(\.diff.path) == ["README.md", "untracked.txt"])
        #expect(all.additions == 3)
    }

    @Test func untrackedFilesAreSynthesisedAsAdditions() async throws {
        let repo = try await FixtureRepo()
        try repo.write("text.txt", "one\ntwo")
        try Data([0, 1, 2]).write(to: repo.main.appending(path: "blob.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.main.appending(path: "link").path, withDestinationPath: "text.txt")

        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: try await repo.sha("HEAD"), scope: .all)
        let files = Dictionary(uniqueKeysWithValues: review.files.map { ($0.diff.path, $0) })

        let text = try #require(files["text.txt"])
        #expect(text.diff.hunks.first?.lines.map(\.text) == ["one", "two"])
        #expect(text.diff.hunks.first?.lines.last?.noNewlineAtEnd == true)
        #expect(files["blob.bin"]?.diff.isBinary == true)
        #expect(files["link"]?.diff.newMode == "120000")
        #expect(files["link"]?.diff.hunks.first?.lines.first?.text == "text.txt")
    }

    @Test func userDiffConfigDoesNotChangeTheOutput() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try await repo.run("config", "diff.noprefix", "true")
        try await repo.run("config", "diff.mnemonicPrefix", "true")
        try await repo.run("config", "diff.renames", "false")
        try await repo.run("mv", "README.md", "RENAMED.md")
        try await repo.run("commit", "-q", "-m", "rename")

        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: base, scope: .committed)

        #expect(review.files.count == 1)
        #expect(review.files.first?.diff.status == .renamed(similarity: 100))
        #expect(review.files.first?.diff.oldPath == "README.md")
    }
}

@Suite struct RepositoryServiceTests {
    @Test func listsWorktreesWithBranchesAndOpensFromAnyOfThem() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let service = RepositoryService(git: repo.git)

        let (repository, opened) = try await service.open(feature.appending(path: "."))
        let worktrees = try await service.worktrees(of: repository)

        #expect(opened.path == feature.path)
        #expect(repository.commonDirectory.path == repo.main.appending(path: ".git").path)
        #expect(worktrees.map(\.branch) == ["main", "feature"])
        #expect(worktrees.map(\.isMain) == [true, false])
        #expect(worktrees.allSatisfy { !$0.isMissing })
    }
}

@Suite struct WorktreeActivityTests {
    @Test func countsStagedUnstagedAndUntrackedFiles() async throws {
        let repo = try await FixtureRepo()
        try repo.write("README.md", "edited\n")
        try repo.write("staged.txt", "s\n")
        try await repo.run("add", "staged.txt")
        try repo.write("dir/untracked.txt", "u\n")
        try repo.write(".gitignore", "*.log\n")
        try repo.write("build.log", "ignored\n")

        let activity = try await WorktreeActivityService(git: repo.git).activity(of: repo.main)

        #expect(activity.uncommittedFiles == 4)
        #expect(activity.lastChange != nil)
    }

    @Test func totalsAgainstTheBaseCountCommittedUncommittedAndUntrackedLines() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try await repo.commit("a.txt", "1\n2\n", "add a")
        try repo.write("README.md", "changed\n")
        try repo.write("new.txt", "x\ny\nz")
        try Data([0, 1, 2]).write(to: repo.main.appending(path: "blob.bin"))

        let activity = try await WorktreeActivityService(git: repo.git).activity(
            of: repo.main, base: base)

        // a.txt +2, README.md +1 −1, new.txt +3 (no final newline), blob.bin no lines.
        #expect(activity.changes == DiffStat(files: 4, additions: 6, deletions: 1))
        #expect(
            try await WorktreeActivityService(git: repo.git).activity(of: repo.main).changes == nil)
    }

    @Test func cleanWorktreeReportsTheHeadCommitTime() async throws {
        let repo = try await FixtureRepo()
        let committed = try await repo.run("log", "-1", "--format=%ct")

        let activity = try await WorktreeActivityService(git: repo.git).activity(of: repo.main)

        #expect(activity.uncommittedFiles == 0)
        #expect(activity.lastChange == Date(timeIntervalSince1970: try #require(Double(committed))))
    }
}

@Suite struct GeneratedFileTests {
    @Test func attributesAndGlobsMarkGeneratedFilesWhichSortLast() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try repo.write(
            ".gitattributes", "api/** linguist-generated\nyarn.lock -linguist-generated\n")
        try repo.write("api/client.ts", "x\n")
        try repo.write("src/Generated/Model.cs", "x\n")
        try repo.write("package-lock.json", "{}\n")
        try repo.write("yarn.lock", "x\n")
        try repo.write("src/app.ts", "x\n")

        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: base, scope: .all)

        #expect(
            review.files.map(\.diff.path) == [
                "src/app.ts", ".gitattributes", "yarn.lock", "api/client.ts",
                "src/Generated/Model.cs", "package-lock.json",
            ])
        #expect(review.files.map(\.isGenerated) == [false, false, false, true, true, true])
        #expect(review.files.map(\.startsCollapsed) == [false, false, false, true, true, true])
    }
}

@Suite struct DiffStatTests {
    @Test(arguments: [
        (
            " 19 files changed, 454 insertions(+), 948 deletions(-)\n",
            DiffStat(files: 19, additions: 454, deletions: 948)
        ),
        (" 1 file changed, 1 insertion(+)\n", DiffStat(files: 1, additions: 1, deletions: 0)),
        (" 2 files changed, 3 deletions(-)\n", DiffStat(files: 2, additions: 0, deletions: 3)),
        ("", DiffStat(files: 0, additions: 0, deletions: 0)),
    ])
    func shortstatLinesParse(line: String, expected: DiffStat) {
        #expect(DiffStat.parse(line) == expected)
    }
}

@Suite struct TreeOrderTests {
    @Test func foldersComeBeforeFilesAtEachLevelThenNames() {
        let paths = ["notes.md", "src/b.cs", "src/a/z.cs", "README.md", "src/c.cs", "app.json"]
        #expect(
            paths.sorted(by: ReviewDiffBuilder.precedesInTree) == [
                "src/a/z.cs", "src/b.cs", "src/c.cs", "README.md", "app.json", "notes.md",
            ])
    }
}
