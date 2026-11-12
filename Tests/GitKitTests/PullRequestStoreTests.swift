import Foundation
import TestSupport
import Testing

@testable import GitKit

/// Pull requests fetched into Seam's own store, never the reader's repo (SPEC §8.3.1, ADR 0008).
@Suite(.timeLimit(.minutes(1))) struct PullRequestStoreTests {
    private let repo: FixtureRepo
    private let store: CLIPullRequestStore
    private let gitHub = GitHubRepo(host: "github.com", owner: "owner", name: "app")

    init() async throws {
        repo = try await FixtureRepo()
        let origin = repo.origin.path
        store = CLIPullRequestStore(
            directory: repo.directory.resolved.appending(path: "store/pulls.git"),
            objects: repo.main.appending(path: ".git/objects"), remoteURL: { _ in origin })
    }

    private func inStore(_ arguments: String...) async throws -> String {
        try await repo.git.string(["--git-dir=\(store.directory.path)"] + arguments, in: repo.main)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the repo has: refs, objects and whether a fetch left FETCH_HEAD.
    private func repoState() async throws -> [String] {
        [
            try await repo.run("for-each-ref"),
            try await repo.run("count-objects", "-v"),
            String(
                FileManager.default.fileExists(
                    atPath: repo.main.appending(path: ".git/FETCH_HEAD").path)),
        ]
    }

    @Test func aPullRequestOnlyOriginHasIsFetchedIntoTheStoreAndTheRepoIsUntouched() async throws {
        let head = try await repo.openPullRequest(8, file: "b.txt", "b\n")
        let before = try await repoState()
        await #expect(throws: (any Error).self) { try await repo.run("cat-file", "-e", head) }

        try await store.fetch(pullRequests: [8], bases: ["main"], from: gitHub)

        #expect(try await inStore("rev-parse", "refs/seam/pull/8") == head)
        #expect(try await inStore("rev-parse", "refs/seam/base/main") == repo.sha("origin/main"))
        #expect(try await inStore("show", "\(head):b.txt") == "b")
        #expect(try await repoState() == before)
    }

    @Test func whatTheRepoAlreadyHasIsReadFromItNotStoredAgain() async throws {
        try await repo.openPullRequest(8, file: "b.txt", "b\n")

        try await store.fetch(pullRequests: [8], bases: ["main"], from: gitHub)

        #expect(
            try String(
                contentsOf: store.directory.appending(path: "objects/info/alternates"),
                encoding: .utf8) == repo.main.appending(path: ".git/objects").path + "\n")
        // The base's README is the repo's object, read through the alternate.
        #expect(try await inStore("show", "refs/seam/base/main:README.md") == "fixture")
    }

    @Test func aPullRequestNoLongerAskedForLosesItsRef() async throws {
        try await repo.openPullRequest(8, file: "b.txt", "b\n")
        try await repo.openPullRequest(9, file: "c.txt", "c\n")
        try await store.fetch(pullRequests: [8, 9], bases: ["main"], from: gitHub)

        try await store.fetch(pullRequests: [9], bases: ["main"], from: gitHub)

        #expect(
            try await inStore("for-each-ref", "--format=%(refname)", "refs/seam/pull/")
                == "refs/seam/pull/9")
    }

    @Test func aResetStoreIsMadeAgainByTheNextFetch() async throws {
        let head = try await repo.openPullRequest(8, file: "b.txt", "b\n")
        try await store.fetch(pullRequests: [8], bases: [], from: gitHub)

        await store.reset()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        try await store.fetch(pullRequests: [8], bases: [], from: gitHub)

        #expect(try await inStore("rev-parse", "refs/seam/pull/8") == head)
    }
}
