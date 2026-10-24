import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

@Suite(.timeLimit(.minutes(1))) struct FileContentsTests {
    @Test func committedScopeReadsBothSidesFromBlobs() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try await repo.commit("README.md", "fixture\ncommitted\n", "edit")
        try repo.write("README.md", "fixture\ncommitted\nuncommitted\n")
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: base, scope: .committed)

        let contents = try await FileContentLoader(git: repo.git).load(review, worktree: repo.main)

        #expect(
            contents["README.md"] == FileContents(old: "fixture\n", new: "fixture\ncommitted\n"))
    }

    @Test func workingTreeScopesReadTheNewSideFromDisk() async throws {
        let repo = try await FixtureRepo()
        let base = try await repo.sha("HEAD")
        try repo.write("README.md", "fixture\nedited\n")
        try repo.write("new.txt", "new\n")
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: base, scope: .all)

        let contents = try await FileContentLoader(git: repo.git).load(review, worktree: repo.main)

        #expect(contents["README.md"] == FileContents(old: "fixture\n", new: "fixture\nedited\n"))
        #expect(contents["new.txt"] == FileContents(old: nil, new: "new\n"))
    }

    @Test func deletedAndBinaryFilesHaveOnlyTheirTextSides() async throws {
        let repo = try await FixtureRepo()
        try await repo.commit("gone.txt", "bye\n", "add")
        try Data([0, 1, 2]).write(to: repo.main.appending(path: "blob.bin"))
        try await repo.run("add", "blob.bin")
        try await repo.run("commit", "-q", "-m", "binary")
        let base = try await repo.sha("HEAD")
        try await repo.run("rm", "-q", "gone.txt")
        try Data([0, 1, 3]).write(to: repo.main.appending(path: "blob.bin"))
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: base, scope: .all)

        let contents = try await FileContentLoader(git: repo.git).load(review, worktree: repo.main)

        #expect(contents["gone.txt"] == FileContents(old: "bye\n", new: nil))
        #expect(contents["blob.bin"] == FileContents(oldSize: 3, newSize: 3))
    }

    @Test func imagesCarryTheirBytesForThePreview() async throws {
        let repo = try await FixtureRepo()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        try png.write(to: repo.main.appending(path: "logo.png"))
        try await repo.run("add", "logo.png")
        try await repo.run("commit", "-q", "-m", "logo")
        let base = try await repo.sha("HEAD")
        let bigger = png + Data([1, 2, 3])
        try bigger.write(to: repo.main.appending(path: "logo.png"))
        try await repo.run("commit", "-q", "-am", "bigger logo")
        let review = try await ReviewDiffBuilder(git: repo.git).build(
            worktree: repo.main, base: base, scope: .committed)

        let contents = try await FileContentLoader(git: repo.git).load(review, worktree: repo.main)

        #expect(
            contents["logo.png"]
                == FileContents(oldSize: 12, newSize: 15, oldImage: png, newImage: bigger))
    }

    @Test func batchOutputWithAMissingObjectIsParsed() throws {
        let data = Data("abc blob 3\nhi\n\nmissing1 missing\ndef blob 0\n\n".utf8)
        #expect(
            try FileContentLoader.parseBatch(data) == ["abc": Data("hi\n".utf8), "def": Data()])
    }

    @Test func truncatedBatchOutputIsAnError() {
        #expect(throws: GitError.self) {
            try FileContentLoader.parseBatch(Data("abc blob 10\nshort\n".utf8))
        }
    }
}
