import AppKit
import Foundation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import Features
@testable import ReviewModel

/// The worktree and commit rows' context menus and their menu-bar twins (SPEC §7.2, §7.2.1).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RowActionsTests {
    private func titles(_ groups: [[FileActions.Action]]) -> [[String]] {
        groups.map { $0.map(\.title) }
    }

    @Test func aWorktreeRowOffersItsFolderPathAndBranch() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        let review = try #require(session.reviews.first { $0.id == tree.path })

        let groups = RowActions.actions(for: review, in: session)

        #expect(
            titles(groups) == [
                ["Open in Editor", "Reveal in Finder"], ["Copy Path", "Copy Branch Name"],
            ])
        #expect(groups.joined().allSatisfy { $0.isEnabled })
        session.copyWorktreePath(of: review)
        #expect(session.platform?.copied.last == tree.path)
        session.copyBranchName(of: review)
        #expect(session.platform?.copied.last == "feature")
    }

    @Test func aDetachedWorktreeHasNoBranchToCopy() async throws {
        let repo = try await FixtureRepo()
        let spike = repo.main.deletingLastPathComponent().appending(path: "wt-spike")
        try await repo.run("worktree", "add", "-q", "--detach", spike.path, "HEAD")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        let review = try #require(session.reviews.first { $0.worktree.isDetached })
        session.select(review.id)

        #expect(
            !titles(RowActions.actions(for: review, in: session)).joined().contains(
                "Copy Branch Name"))
        #expect(try command("worktree-copy-branch").isEnabled(session) == false)
        #expect(try command("worktree-copy-path").isEnabled(session))
    }

    @Test func aMissingWorktreeCanOnlyBeCopied() async throws {
        let repo = try await FixtureRepo()
        let gone = try await repo.worktree("gone", branch: "gone", from: "origin/main")
        try FileManager.default.removeItem(at: gone)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        let review = try #require(session.reviews.first { $0.id == gone.path })
        session.select(review.id)

        let enabled = RowActions.actions(for: review, in: session).joined()
            .filter(\.isEnabled).map(\.title)
        #expect(enabled == ["Copy Path", "Copy Branch Name"])
        #expect(try command("worktree-editor").isEnabled(session) == false)
        #expect(try command("worktree-reveal").isEnabled(session) == false)
    }

    @Test func openingAWorktreeInTheEditorOpensItsFolder() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let launcher = FakeLauncher()
        var services = services(repo.git)
        services.launcher = launcher
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        let review = try #require(session.reviews.first { $0.id == tree.path })

        session.openWorktreeInEditor(review, command: EditorCommand(template: "zed {path}:{line}"))

        #expect(await launcher.next() == "zed " + EditorCommand.quoted(tree.path))
    }

    @Test func aFolderOpensWithoutTheLineOrTheOptionThatTakesIt() {
        let lines = EditorCommand.presets.map {
            EditorCommand(template: $0.template).commandLine(directory: "/a b")
        }
        #expect(lines == ["zed '/a b'", "code '/a b'", "rider '/a b'", "cursor '/a b'"])
        #expect(
            EditorCommand(template: "ed +{line} {path}").commandLine(directory: "/a") == "ed '/a'")
    }

    @Test func aCommitRowCopiesItsIDAndSubjectAndPicksItself() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let first = try await repo.commit("a.txt", "a\n", "Add a", in: tree)
        let second = try await repo.commit("b.txt", "b\n", "Add b", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)

        // A right-click inside a two-commit selection acts on the newer one.
        let groups = RowActions.actions(
            for: [.commit(first), .commit(second)], of: review, in: session)
        #expect(
            titles(groups) == [["Copy Commit ID", "Copy Subject"], ["Show Only This Commit"]])
        let log = try #require(review.commitLog)
        session.copyCommitID(log.commits[0])
        #expect(session.platform?.copied.last == second)
        session.copySubject(of: log.commits[1])
        #expect(session.platform?.copied.last == "Add a")

        let older = RowActions.actions(for: [.commit(first)], of: review, in: session)
        older[1][0].run()
        await session.settled()
        #expect(review.newestSelectedCommit?.id == first)
        let picked = RowActions.actions(for: [.commit(first)], of: review, in: session)
        #expect(titles(picked)[1] == ["Show Only This Commit", "Show All Changes"])
        #expect(picked[1][0].isEnabled == false)
        #expect(RowActions.actions(for: [.workingTree], of: review, in: session).isEmpty)
    }

    @Test func theMenuBarCopiesTheNewestCommitTheDiffCovers() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("a.txt", "a\n", "Add a", in: tree)
        let newest = try await repo.commit("b.txt", "b\n", "Add b", in: tree)
        try repo.write("c.txt", "c\n", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()
        let review = try #require(session.selected)
        let copy = try command("copy-commit-id")

        // All Changes starts at the uncommitted row; the newest commit under it is what's copied.
        #expect(review.newestSelectedCommit?.id == newest)
        #expect(copy.isEnabled(session))

        session.setScope(.uncommitted)
        await session.settled()
        #expect(review.newestSelectedCommit == nil)
        #expect(!copy.isEnabled(session))
    }
}
