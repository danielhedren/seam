import Foundation
import SeamCore
import TestSupport
import Testing

@testable import Features

@Suite struct StateStoreTests {
    @Test func recentReposAreNewestFirstUniqueAndCapped() async throws {
        let directory = try TemporaryDirectory()
        let store = JSONStateStore(root: directory.resolved)
        for index in 0..<12 { await store.noteOpened(URL(fileURLWithPath: "/repo\(index)")) }
        await store.noteOpened(URL(fileURLWithPath: "/repo3"))

        let recent = await store.recentRepositories().map(\.path)

        #expect(recent.count == 10)
        #expect(recent.prefix(3) == ["/repo3", "/repo11", "/repo10"])
        #expect(Set(recent).count == 10)
        await store.clearRecent()
        #expect(await store.recentRepositories().isEmpty)
    }

    @Test func repoStateRoundTripsThroughJSON() async throws {
        let directory = try TemporaryDirectory()
        let store = JSONStateStore(root: directory.resolved)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/.git"), anchor: URL(fileURLWithPath: "/r"))
        var state = RepoState()
        state.baseOverrides["feature"] = "refs/heads/main"
        state.selectedWorktree = "/r"
        state.worktrees["/r"] = .init(
            scope: "all", mode: "split", wraps: true, viewed: ViewedMarks(marks: ["a": "1"]))

        await store.save(state, for: repository)

        #expect(await store.load(repository) == state)
    }
}
