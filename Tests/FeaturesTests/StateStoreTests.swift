import Foundation
import SeamCore
import TestSupport
import Testing

@testable import Features

@Suite(.timeLimit(.minutes(1))) struct StateStoreTests {
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
            scope: "all", wraps: true, viewed: ViewedMarks(marks: ["a": "1"]))

        await store.save(state, for: repository)

        #expect(await store.load(repository) == state)
    }

    /// A state file in today's format, as a build of Seam wrote it: a change to the shape shows
    /// here instead of silently resetting the reader's viewed marks and bases.
    @Test func aStateFileInTodaysFormatReads() throws {
        let json = """
            {"baseOverrides":{"refs/heads/feature":"refs/remotes/origin/parent"},
             "selectedWorktree":"/r",
             "worktrees":{"/r":{"scope":"all","wraps":true,"viewed":{"marks":{"a.txt":"9f2c"}},
               "dismissedStaleParents":["refs/heads/old"],"currentFile":"a.txt",
               "anchor":{"path":"a.txt","line":12,"isOldSide":false,"offset":4}}},
             "pullRequests":{"byBranch":{},"baseRefs":{"feature":"refs/remotes/origin/main"},
               "unpushed":{"feature":2},"read":782913600}}
            """
        // The default date coding, seconds since 2001, as JSONStateStore writes it.
        let state = try JSONDecoder().decode(RepoState.self, from: Data(json.utf8))
        #expect(state.baseOverrides == ["refs/heads/feature": "refs/remotes/origin/parent"])
        #expect(state.worktrees["/r"]?.viewed?.marks == ["a.txt": "9f2c"])
        #expect(state.worktrees["/r"]?.anchor == ScrollAnchor(path: "a.txt", line: 12, offset: 4))
        #expect(state.pullRequests?.unpushed == ["feature": 2])
        #expect(state.pullRequests?.read == Date(timeIntervalSinceReferenceDate: 782_913_600))
    }

    @Test @MainActor func theCommandReadsTheBaseChoicesTheAppSaves() async throws {
        let directory = try TemporaryDirectory()
        let store = JSONStateStore(root: directory.resolved)
        let repository = Repository(
            commonDirectory: URL(fileURLWithPath: "/r/.git"), anchor: URL(fileURLWithPath: "/r"))
        var state = RepoState()
        state.baseOverrides["refs/heads/feature"] = "refs/remotes/origin/parent"
        // A full file, as the app writes it: the command reads the same type.
        state.worktrees["/r"] = .init(
            scope: "all", viewed: ViewedMarks(marks: ["a": "1"]),
            anchor: ScrollAnchor(path: "a", line: 3, offset: 2), currentFile: "a")
        state.pullRequests = SavedPullRequests(baseRefs: ["feature": "refs/remotes/origin/main"])
        await store.save(state, for: repository)
        let defaults = Scratch.defaults("seam-choices")
        let settings = AppSettings(defaults: defaults)
        settings.defaultBase = "origin/develop"
        settings.ignoredRefs = ["origin/wip/**"]

        #expect(AppChoices.detectionSettings(defaults) == settings.detection)
        #expect(
            AppChoices.baseOverride(
                branch: "refs/heads/feature", of: repository, in: directory.resolved)
                == "refs/remotes/origin/parent")
        #expect(
            AppChoices.baseOverride(
                branch: "refs/heads/other", of: repository, in: directory.resolved)
                == nil)
    }
}
