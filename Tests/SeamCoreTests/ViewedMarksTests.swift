import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct ViewedMarksTests {
    private func file(_ path: String, new: String?, old: String? = "aaa", deleted: Bool = false)
        -> ReviewFile
    {
        var diff = FileDiff(
            oldPath: path, newPath: deleted ? nil : path, status: deleted ? .deleted : .modified)
        diff.oldBlob = old
        diff.newBlob = new
        return ReviewFile(diff: diff)
    }

    @Test func markingRecordsTheContentAndAChangeShowsAsChangedSinceViewed() {
        var marks = ViewedMarks()
        #expect(marks.status(of: file("a.swift", new: "111")) == .unviewed)

        marks.toggle(file("a.swift", new: "111"))
        #expect(marks.status(of: file("a.swift", new: "111")) == .viewed)
        #expect(marks.status(of: file("a.swift", new: "222")) == .changedSinceViewed)

        marks.toggle(file("a.swift", new: "222"))
        #expect(marks.status(of: file("a.swift", new: "222")) == .viewed)
        marks.toggle(file("a.swift", new: "222"))
        #expect(marks.status(of: file("a.swift", new: "222")) == .unviewed)
    }

    @Test func aRebaseThatKeepsAFilesContentKeepsItsMark() {
        var marks = ViewedMarks()
        marks.toggle(file("a.swift", new: "111", old: "base-before-rebase"))
        #expect(marks.status(of: file("a.swift", new: "111", old: "base-after-rebase")) == .viewed)
    }

    @Test func deletedFilesAreMarkedByTheirOldContent() {
        var marks = ViewedMarks()
        let deleted = file("gone.swift", new: "0000000000", old: "abc", deleted: true)
        let marked = marks.toggle(deleted)
        #expect(marked)
        #expect(marks.status(of: deleted) == .viewed)
        #expect(ViewedMarks.contentID(of: deleted) == "deleted:abc")
    }

    @Test func aFileWithoutContentIDCannotBeMarked() {
        var marks = ViewedMarks()
        let marked = marks.toggle(file("x", new: nil))
        #expect(!marked)
        #expect(marks.marks.isEmpty)
    }

    @Test func untrackedFilesGetTheBlobIDGitWouldGiveThem() async throws {
        let repo = try await FixtureRepo()
        try repo.write("new.txt", "new\n")
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: try await repo.sha("HEAD"), scope: .all)
        let expected = try await repo.run("hash-object", "new.txt")

        #expect(review.files.first?.diff.newBlob == expected)
    }

    @Test func aNestedRepositoryInsideTheWorktreeDoesNotBreakTheDiff() async throws {
        let repo = try await FixtureRepo()
        try repo.write("note.txt", "n\n")
        _ = try await repo.git.run(
            ["init", "-q", repo.main.appending(path: ".worktrees/agent").path], in: repo.main)
        try repo.write(".worktrees/agent/inner.txt", "i\n")

        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: try await repo.sha("HEAD"), scope: .all)

        let note = try #require(review.files.first { $0.diff.path == "note.txt" })
        #expect(note.diff.newBlob == (try await repo.run("hash-object", "note.txt")))
        #expect(review.files.contains { $0.diff.path.hasPrefix(".worktrees/agent") })
    }

    @Test func symlinksGetGitsBlobIDForTheirTarget() async throws {
        let repo = try await FixtureRepo()
        try FileManager.default.createSymbolicLink(
            atPath: repo.main.appending(path: "link").path, withDestinationPath: "target.txt")
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: try await repo.sha("HEAD"), scope: .all)
        try await repo.run("add", "link")
        let staged = try await repo.run("ls-files", "-s", "link")

        #expect(staged.contains(try #require(review.files.first?.diff.newBlob)))
    }
}
