import Foundation
import GitKit
import Synchronization
import TestSupport
import Testing

@testable import SeamCore

/// Hands out scripted batches and reports when the consumer is waiting for the next one, which
/// is the point where the previous batch has been fully processed.
private final class FakeWatcher: FileWatcher, Sendable {
    private struct State {
        var queue: [[String]] = []
        var consumer: CheckedContinuation<[String]?, Never>?
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var finished = false
    }

    private let state = Mutex(State())

    func events(for directories: [URL]) -> AsyncStream<[String]> {
        AsyncStream(unfolding: { await self.next() })
    }

    func send(_ paths: String...) {
        let consumer = state.withLock { state in
            guard let consumer = state.consumer else {
                state.queue.append(paths)
                return CheckedContinuation<[String]?, Never>?.none
            }
            state.consumer = nil
            return consumer
        }
        consumer?.resume(returning: paths)
    }

    func finish() {
        let consumer = state.withLock { state in
            state.finished = true
            defer { state.consumer = nil }
            return state.consumer
        }
        consumer?.resume(returning: nil)
    }

    /// Returns once every sent batch has been taken and processed.
    func idle() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                guard state.consumer == nil || !state.queue.isEmpty else { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func next() async -> [String]? {
        await withCheckedContinuation { continuation in
            let (batch, waiters) = state.withLock {
                state -> ([String]??, [CheckedContinuation<Void, Never>]) in
                if !state.queue.isEmpty { return (state.queue.removeFirst(), []) }
                if state.finished { return (.some(nil), []) }
                state.consumer = continuation
                defer { state.idleWaiters = [] }
                return (nil, state.idleWaiters)
            }
            for continuation in waiters { continuation.resume() }
            if let batch { continuation.resume(returning: batch) }
        }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ChangeClassifierTests {
    private let repository = Repository(
        commonDirectory: URL(fileURLWithPath: "/r/.git", isDirectory: true),
        anchor: URL(fileURLWithPath: "/r", isDirectory: true))

    private func worktree(_ path: String, gitDirectory: String) -> Worktree {
        Worktree(
            path: URL(fileURLWithPath: path, isDirectory: true), head: nil, branch: nil,
            isMain: path == "/r", isDetached: false, isLocked: false, isPrunable: false,
            isMissing: false, gitDirectory: URL(fileURLWithPath: gitDirectory, isDirectory: true))
    }

    private var classifier: ChangeClassifier {
        ChangeClassifier(
            repository: repository,
            worktrees: [
                worktree("/r", gitDirectory: "/r/.git"),
                worktree("/r/.worktrees/a", gitDirectory: "/r/.git/worktrees/a"),
            ])
    }

    @Test func workingTreePathsGoToTheInnermostWorktree() {
        let result = classifier.classify(["/r/src/x.swift", "/r/.worktrees/a/src/y.swift"])
        #expect(result.files == ["/r": ["src/x.swift"], "/r/.worktrees/a": ["src/y.swift"]])
        #expect(result.change.isEmpty)
    }

    @Test func refsHeadsAndPackedRefsAreRefChanges() {
        for path in [
            "/r/.git/refs/heads/main", "/r/.git/packed-refs", "/r/.git/HEAD",
            "/r/.git/worktrees/a/HEAD", "/r/.git/worktrees/b",
        ] {
            #expect(classifier.classify([path]).change.refs, "\(path)")
        }
    }

    @Test func indexWritesRefreshTheirOwnWorktree() {
        let main = classifier.classify(["/r/.git/index"]).change
        let linked = classifier.classify(["/r/.git/worktrees/a/index"]).change
        #expect(main == RepoChange(worktrees: ["/r"]))
        #expect(linked == RepoChange(worktrees: ["/r/.worktrees/a"]))
    }

    @Test func objectsLogsAndLockFilesAreIgnored() {
        let result = classifier.classify([
            "/r/.git/objects/ab/cdef", "/r/.git/logs/HEAD", "/r/.git/refs/heads/x.lock",
            "/r/.git/index.lock", "/r/.worktrees/a/.git", "/elsewhere/file",
        ])
        #expect(result == ChangeClassifier.Result())
    }

    @Test func nestedRootsAreNotWatchedTwice() {
        #expect(classifier.watchedDirectories.map(\.path) == ["/r"])
    }
}

@Suite(.timeLimit(.minutes(1))) struct RepoMonitorTests {
    private struct Setup {
        let repo: FixtureRepo
        let watcher = FakeWatcher()
        let clock = ManualClock()
        let monitor: RepoMonitor

        init() async throws {
            repo = try await FixtureRepo()
            _ = try await repo.worktree("feature", branch: "feature", from: "origin/main")
            try repo.write(".gitignore", "build/\n")
            let service = RepositoryService(git: repo.git)
            let (repository, _) = try await service.open(repo.main)
            monitor = RepoMonitor(
                repository: repository, worktrees: try await service.worktrees(of: repository),
                watcher: watcher, git: repo.git, clock: clock)
        }

        func path(_ relative: String) -> String { repo.main.appending(path: relative).path }
    }

    @Test func eventsWithinTheWindowArriveAsOneChange() async throws {
        let setup = try await Setup()
        var changes = setup.monitor.changes().makeAsyncIterator()

        setup.watcher.send(setup.path("README.md"))
        await setup.watcher.idle()
        await setup.clock.sleepers()
        setup.watcher.send(setup.path(".git/refs/heads/main"))
        await setup.watcher.idle()
        setup.clock.advance(by: .milliseconds(299))
        #expect(setup.clock.sleeperCount == 1)
        setup.clock.advance(by: .milliseconds(1))

        let change = try #require(await changes.next())
        #expect(change == RepoChange(worktrees: [setup.repo.main.path], refs: true))
    }

    @Test func ignoredPathsNeitherOpenTheWindowNorAppearInIt() async throws {
        let setup = try await Setup()
        let feature = setup.repo.directory.resolved.appending(path: "wt-feature")
        var changes = setup.monitor.changes().makeAsyncIterator()

        setup.watcher.send(setup.path("build/out.o"))
        await setup.watcher.idle()
        setup.watcher.send(setup.path("build/more.o"), feature.appending(path: "f.txt").path)
        await setup.watcher.idle()
        await setup.clock.sleepers()
        setup.clock.advance(by: .milliseconds(300))

        let change = try #require(await changes.next())
        #expect(change == RepoChange(worktrees: [feature.path]))
    }
}

@Suite(.timeLimit(.minutes(1))) struct FileWatcherTests {
    @Test func reportsAWrittenFile() async throws {
        let directory = try TemporaryDirectory()
        let root = directory.resolved
        let file = root.appending(path: "written.txt")
        let events = SystemFileWatcher().events(for: [root])

        try Data("x".utf8).write(to: file)

        for await batch in events where batch.contains(file.path) { return }
        Issue.record("the stream ended without reporting \(file.path)")
    }

    /// inotify watches single folders, so one made after watching starts must be added.
    @Test func reportsAFileInAFolderMadeAfterWatchingStarted() async throws {
        let directory = try TemporaryDirectory()
        let root = directory.resolved
        let folder = root.appending(path: "new/deeper")
        let file = folder.appending(path: "written.txt")
        let events = SystemFileWatcher().events(for: [root])

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var wrote = false
        for await batch in events {
            if !wrote, batch.contains(where: { $0.hasPrefix(root.appending(path: "new").path) }) {
                try Data("x".utf8).write(to: file)
                wrote = true
            }
            if batch.contains(file.path) { return }
        }
        Issue.record("the stream ended without reporting \(file.path)")
    }
}
