import DiffModel
import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import Synchronization
import TestSupport
import Testing

@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct RepoSessionTests {
    @Test func openingAWorktreeListsAllRowsAndShowsItsDiff() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        try await repo.commit("f.txt", "f\n", "f1", in: feature)
        try repo.write("draft.txt", "d\n", in: feature)
        let session = RepoSession(directory: feature, services: services(repo.git))

        await session.open()
        await session.settled()

        #expect(session.state == .open)
        #expect(session.sortedReviews.map(\.worktree.name) == ["wt-feature", "repo"])
        let review = try #require(session.selected)
        #expect(review.id == feature.path)
        #expect(review.parentName == "origin/main")
        #expect(review.uniqueCommitCount == 1)
        #expect(review.activity?.uncommittedFiles == 1)
        #expect(review.diff?.files.map(\.diff.path) == ["draft.txt", "f.txt"])
        #expect(review.problem == nil)
    }

    @Test func theListShowsBeforeRowsHaveTheirCounts() async throws {
        let repo = try await FixtureRepo()
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        let git = GatedGit(repo.git, holding: other, command: "status")
        let session = RepoSession(directory: repo.main, services: services(git))

        await session.open()

        #expect(session.state == .open)
        #expect(session.reviews.first { $0.id == other.path }?.activity == nil)
        git.release()
        await session.rowsLoaded()
        #expect(session.reviews.first { $0.id == other.path }?.activity?.uncommittedFiles == 0)
    }

    @Test func aFolderOutsideGitExplainsWhatToDo() async throws {
        let directory = try TemporaryDirectory()
        let session = RepoSession(
            directory: directory.resolved,
            services: services(HermeticGit(home: directory.resolved)))

        await session.open()

        #expect(session.state == .failed("Not a git repository. Choose another folder."))
    }

    @Test func switchingWorktreesAbandonsTheOldLoad() async throws {
        let repo = try await FixtureRepo()
        let slow = try await repo.worktree("slow", branch: "slow", from: "origin/main")
        try repo.write("slow.txt", "s\n", in: slow)
        let fast = try await repo.worktree("fast", branch: "fast", from: "origin/main")
        try repo.write("fast.txt", "f\n", in: fast)
        let git = GatedGit(repo.git, holding: slow)
        let session = RepoSession(directory: repo.main, services: services(git))
        await session.open()
        await session.settled()

        session.select(slow.path)
        let slowReview = try #require(session.selected)
        while git.heldCount == 0 { await Task.yield() }
        session.select(fast.path)
        await session.settled()
        git.release()
        await slowReview.loaded()

        #expect(session.selected?.id == fast.path)
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["fast.txt"])
        #expect(slowReview.diff == nil)
        #expect(!slowReview.isLoading)
    }

    @Test func switchingAwayDuringAReloadLeavesTheOldWorktreeUnloaded() async throws {
        let repo = try await FixtureRepo()
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        let git = GatedGit(repo.git, holding: repo.main, command: "status")
        git.release()
        let session = RepoSession(directory: repo.main, services: services(git))
        await session.open()
        await session.settled()
        let main = try #require(session.selected)
        let version = main.diffVersion

        git.close()
        let held = git.heldCount
        session.reload()
        while git.heldCount == held { await Task.yield() }
        session.select(other.path)
        git.release()
        await session.settled()
        await main.loaded()

        #expect(session.selected?.id == other.path)
        #expect(main.diffVersion == version)
    }

    @Test func aWorkingTreeChangeReloadsTheSelectedDiffAndKeepsTheSelection() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        #expect(session.selected?.diff?.files.isEmpty == true)

        try repo.write("new.txt", "n\n")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()

        #expect(session.selected?.id == repo.main.path)
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["new.txt"])
        #expect(session.selected?.activity?.uncommittedFiles == 1)
    }

    @Test func aHiddenWorktreesCountsCatchUpAtTheEndOfTheQuietPeriod() async throws {
        let repo = try await FixtureRepo()
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        let clock = ManualClock()
        let session = RepoSession(directory: repo.main, services: services(repo.git, clock: clock))
        await session.open()
        await session.settled()
        let hidden = try #require(session.reviews.first { $0.id == other.path })

        try repo.write("a.txt", "a\n", in: other)
        await session.apply(RepoChange(worktrees: [other.path]))
        await until { hidden.activity?.uncommittedFiles == 1 }
        await clock.sleepers()
        try repo.write("b.txt", "b\n", in: other)
        await session.apply(RepoChange(worktrees: [other.path]))
        clock.advance(by: .seconds(5))

        await until { hidden.activity?.uncommittedFiles == 2 }
        session.close()
    }

    /// Two counts can be in flight (the monitor and a reload); the older one finishing last
    /// mustn't put back what it saw.
    @Test func anOlderStatusFinishingLastDoesntOverwriteTheNewerOne() async throws {
        let repo = try await FixtureRepo()
        let git = HoldsNextStatus(repo.git)
        let session = RepoSession(directory: repo.main, services: services(git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)

        git.arm()
        let older = Task { await review.refreshActivity() }
        await git.held()
        try repo.write("new.txt", "x\n")
        await review.refreshActivity()
        #expect(review.activity?.uncommittedFiles == 1)
        git.release()
        await older.value
        #expect(review.activity?.uncommittedFiles == 1)
        session.close()
    }

    /// What Seam couldn't save shows above the diff, as a thread that couldn't be saved does.
    @Test func stateThatCantBeSavedSaysSoAboveTheDiff() async throws {
        let repo = try await FixtureRepo()
        let store = FailingStore()
        let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await session.open()
        await session.settled()
        session.noteReading("a.txt")
        await session.settled()
        #expect(session.stateProblem == "disk full")
        session.dismissStateProblem()
        #expect(session.stateProblem == nil)
        session.close()
    }

    /// After a fetch, the diff being read reloads first; the other rows' counts follow and
    /// don't hold it up.
    @Test func aRefChangeReloadsTheShownDiffBeforeEveryRowIsCounted() async throws {
        let repo = try await FixtureRepo()
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let git = GatedGit(repo.git, holding: other, command: "status")
        git.release()
        let session = RepoSession(directory: feature, services: services(git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.diff?.files.isEmpty == true)

        git.close()
        try await repo.commit("f.txt", "f\n", "Add f", in: feature)
        await session.apply(RepoChange(refs: true))
        await review.loaded()
        #expect(review.diff?.files.map(\.diff.path) == ["f.txt"])
        #expect(git.heldCount > 0, "the other row's count is still waiting")
        git.release()
        await session.settled()
        session.close()
    }

    /// Scrolling through files writes at once (nothing runs on ⌘Q), but saves asked for while
    /// one is being written become one more write, not one each; gone worktrees aren't kept.
    @Test func savesWhileOneIsWrittenBecomeOneMoreAndForgetGoneWorktrees() async throws {
        let repo = try await FixtureRepo()
        let store = HoldingStore()
        let repository = try await RepositoryService(git: repo.git).open(repo.main).0
        var stale = RepoState()
        stale.worktrees["/gone"] = .init(scope: "all")
        await store.seed(stale, for: repository)
        let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await session.open()
        await session.settled()
        let before = await store.saves

        await store.hold()
        session.noteReading("a.txt")
        await store.held()
        for path in ["b.txt", "c.txt", "d.txt"] { session.noteReading(path) }
        await store.release()
        await session.settled()
        #expect(await store.saves == before + 2)
        let saved = await store.load(repository)
        #expect(saved.worktrees[repo.main.path]?.currentFile == "d.txt")
        #expect(saved.worktrees["/gone"] == nil)
        session.close()
    }

    @Test func aRefChangeRedetectsTheParent() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "origin/main")
        let session = RepoSession(directory: c, services: services(repo.git))
        await session.open()
        await session.settled()
        #expect(session.selected?.parentName == "origin/main")

        try await repo.run("reset", "-q", "--hard", "b", in: c)
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        await session.apply(RepoChange(refs: true))
        await session.settled()

        #expect(session.selected?.parentName == "b")
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["c.txt"])
    }

    @Test func baseOverrideDiffsAgainstTheChosenParentAndIsRemembered() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let store = MemoryStore()
        let session = RepoSession(directory: c, services: services(repo.git, store: store))
        await session.open()
        await session.settled()
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["c.txt"])

        session.setBaseOverride("refs/remotes/origin/main")
        await session.settled()
        #expect(session.selected?.parentName == "origin/main")
        #expect(session.selected?.uniqueCommitCount == 2)
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["b.txt", "c.txt"])

        let reopened = RepoSession(directory: c, services: services(repo.git, store: store))
        await reopened.open()
        await reopened.settled()
        #expect(reopened.selected?.baseOverride == "refs/remotes/origin/main")
    }

    @Test func anOverrideThatNoLongerResolvesKeepsNoCountsFromTheOneBefore() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let session = RepoSession(directory: c, services: services(repo.git))
        await session.open()
        session.setBaseOverride("refs/remotes/origin/main")
        await session.settled()
        #expect(session.selected?.uniqueCommitCount == 2)

        session.setBaseOverride("refs/heads/deleted")
        await session.settled()

        #expect(session.selected?.problem == .overrideGone("deleted"))
        #expect(session.selected?.uniqueCommitCount == nil)
        #expect(session.selected?.activity?.changes == nil)
    }

    @Test func aSupersededLoadLeavesTheNewOverrideAlone() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let git = GatedGit(repo.git, holding: c, command: "rev-list")
        git.release()
        let session = RepoSession(directory: c, services: services(git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)

        git.close()
        let held = git.heldCount
        session.setBaseOverride("refs/remotes/origin/main")
        while git.heldCount == held { await Task.yield() }
        let started = Flag()
        let first = Task {
            started.isSet = true
            await review.loaded()
        }
        while !started.isSet { await Task.yield() }
        session.setBaseOverride("refs/heads/deleted")
        await session.settled()
        git.release()
        await first.value

        #expect(review.problem == .overrideGone("deleted"))
        #expect(review.uniqueCommitCount == nil)
    }

    @Test func aTypedShortRefIsStoredByItsFullName() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let session = RepoSession(directory: c, services: services(repo.git))
        await session.open()
        await session.settled()

        await session.setTypedBase("main")
        await session.settled()

        #expect(session.selected?.baseOverride == "refs/heads/main")
        #expect(session.selected?.uniqueCommitCount == 2)
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["b.txt", "c.txt"])
    }

    @Test func aRefThatLooksLikeAnOptionIsNotPassedToGitAsOne() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()

        await session.setTypedBase("--all")
        await session.settled()

        #expect(session.selected?.problem == .overrideGone("--all"))
    }

    /// Closed before its task gets to run: on the main actor `open()` can't start first.
    @Test func closingBeforeOpenRunsLeavesNothingWatching() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))

        let opening = Task { await session.open() }
        session.close()
        await opening.value

        #expect(!session.isWatching)
        #expect(session.state == .opening)
    }

    /// Closed while the worktrees are being listed, half way through opening.
    @Test func closingWhileOpeningLeavesNothingWatching() async throws {
        let repo = try await FixtureRepo()
        let git = GatedGit(repo.git, holding: repo.main, command: "worktree")
        let session = RepoSession(directory: repo.main, services: services(git))

        let opening = Task { await session.open() }
        while git.heldCount == 0 { await Task.yield() }
        session.close()
        git.release()
        await opening.value

        #expect(!session.isWatching)
        #expect(session.state == .opening)
    }

    @Test func closingWhileTheThreadsLoadLeavesNothingWatching() async throws {
        let repo = try await FixtureRepo()
        let watcher = FirstWatchWatcher()
        let session = RepoSession(
            directory: repo.main,
            services: SeamServices(
                git: repo.git, watcher: watcher, clock: ManualClock(), store: MemoryStore(),
                threads: scratchThreadStore(), settings: testSettings()))
        // The first watch is the threads'; the close lands while their file is read.
        watcher.onFirstWatch { Task { session.close() } }

        await session.open()

        #expect(!session.isWatching)
    }

    @Test func singleLetterKeysStandDownWhileASheetOrPopoverIsOpen() {
        let session = RepoSession(
            directory: URL(fileURLWithPath: "/"),
            services: services(HermeticGit(home: URL(fileURLWithPath: "/"))))
        session.diffHasFocus = true
        #expect(session.reviewHasFocus)
        session.showsSwitcher = true
        #expect(!session.reviewHasFocus)
        session.showsSwitcher = false
        session.showsBasePicker = true
        #expect(!session.reviewHasFocus)
    }

    @Test func fileContentsArriveForExpansionAndSurviveAReload() async throws {
        let repo = try await FixtureRepo()
        let lines = (1...60).map { "line \($0)" }
        try await repo.commit("big.txt", lines.joined(separator: "\n") + "\n", "big")
        var edited = lines
        edited[29] = "line 30 edited"
        try repo.write("big.txt", edited.joined(separator: "\n") + "\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.setBaseOverride("refs/heads/main")
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.contents["big.txt"]?.old?.contains("line 30\n") == true)
        #expect(review.contents["big.txt"]?.new?.contains("line 30 edited") == true)

        review.expand("big.txt", gap: 0, .up)
        review.expand("big.txt", gap: 0, .up)
        edited[59] = "line 60 edited"
        try repo.write("big.txt", edited.joined(separator: "\n") + "\n")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()

        #expect(review.content?.expansions == ["big.txt": [0: GapExpansion(bottom: 40)]])
        #expect(review.contents["big.txt"]?.new?.contains("line 60 edited") == true)
        #expect(review.diff?.files.first?.diff.hunks.count == 2)
    }

    @Test func generatedFilesStartCollapsedUntilTheReaderOpensThem() async throws {
        let repo = try await FixtureRepo()
        try repo.write("package-lock.json", "{}\n")
        try repo.write("app.ts", "x\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.collapsed == ["package-lock.json"])

        session.toggleCollapsed("package-lock.json")
        try repo.write("package-lock.json", "{ }\n")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()

        #expect(review.collapsed.isEmpty)
    }

    @Test func syntaxHighlightsArriveForKnownLanguagesOnly() async throws {
        let repo = try await FixtureRepo()
        try repo.write("main.rs", "let answer = 42;\n")
        try repo.write("notes.txt", "let answer = 42\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        await review.highlighted()

        let spans = try #require(review.syntax["main.rs"]?.new?.first)
        #expect(spans.contains(SyntaxSpan(range: 0..<3, token: .keyword)))
        #expect(review.syntax["notes.txt"] == nil)
    }

    @Test func markingViewedAdvancesUndoesAndSurvivesAReopen() async throws {
        let repo = try await FixtureRepo()
        for name in ["a.txt", "b.txt", "c.txt"] { try repo.write(name, "\(name)\n") }
        let store = MemoryStore()
        let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        #if canImport(Darwin)
            let undo = UndoManager()
            undo.groupsByEvent = false
            session.undoManager = undo
        #endif
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        review.currentFile = "a.txt"

        #if canImport(Darwin)
            undo.beginUndoGrouping()
            session.toggleViewed()
            undo.endUndoGrouping()
        #else
            session.toggleViewed()
        #endif
        #expect(review.viewedStatus("a.txt") == .viewed)
        #expect(review.currentFile == "b.txt")
        #if canImport(Darwin)
            undo.undo()
            #expect(review.viewedStatus("a.txt") == .unviewed)
            undo.redo()
            #expect(review.viewedStatus("a.txt") == .viewed)
        #endif
        await session.settled()

        let reopened = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await reopened.open()
        await reopened.settled()
        #expect(reopened.selected?.viewedStatus("a.txt") == .viewed)
        #expect(reopened.selected?.viewedStatus("b.txt") == .unviewed)
    }

    @Test func editingAViewedFileMarksItChangedSinceViewed() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        session.toggleViewed("a.txt", advance: false)

        try repo.write("a.txt", "two\n")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()

        #expect(session.selected?.viewedStatus("a.txt") == .changedSinceViewed)
        #expect(session.selected?.nextUnviewed(after: nil) == "a.txt")
    }

    @Test func aPrunedParentMakesTheReviewOfferMain() async throws {
        let repo = try await FixtureRepo()
        let b = try await repo.worktree("b", branch: "b", from: "origin/main")
        try await repo.commit("b.txt", "b\n", "b1", in: b)
        try await repo.run("push", "-q", "-u", "origin", "b", in: b)
        try await repo.commit("b.txt", "b\nlocal\n", "b2", in: b)
        let c = try await repo.worktree("c", branch: "c", from: "b")
        try await repo.commit("c.txt", "c\n", "c1", in: c)
        let session = RepoSession(directory: c, services: services(repo.git))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        #expect(review.staleParent == nil)

        _ = try await repo.git.run(
            ["--git-dir", repo.origin.path, "update-ref", "-d", "refs/heads/b"], in: repo.main)
        try await repo.run("fetch", "-q", "--prune", "origin", in: c)
        await session.apply(RepoChange(refs: true))
        await session.settled()

        #expect(review.staleParent?.parent == "b")
        #expect(review.staleParent?.suggestion.name == "origin/main")
        review.dismissStaleParent()
        review.reloadDiff()
        await review.loaded()
        #expect(review.diff != nil)
        #expect(review.staleParent == nil)
    }

    @Test func reopeningRestoresTheWorktreeFileAndScrollPosition() async throws {
        let repo = try await FixtureRepo()
        let feature = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        for name in ["a.txt", "b.txt"] { try repo.write(name, "\(name)\n", in: feature) }
        let store = MemoryStore()
        let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await session.open()
        session.select(feature.path)
        await session.settled()
        session.selected?.currentFile = "b.txt"
        session.selected?.savedAnchor = ScrollAnchor(path: "b.txt", line: 1, offset: 4)
        session.close()
        await session.settled()

        let reopened = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await reopened.open()
        await reopened.settled()

        #expect(reopened.selected?.id == feature.path)
        #expect(reopened.selected?.currentFile == "b.txt")
        #expect(reopened.selected?.savedAnchor == ScrollAnchor(path: "b.txt", line: 1, offset: 4))
    }

    @Test func viewedFilesFoldAwayAndOpenAgainWhenTheyChange() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        #if canImport(Darwin)
            let undo = UndoManager()
            undo.groupsByEvent = false
            session.undoManager = undo
        #endif
        await session.open()
        await session.settled()
        let review = try #require(session.selected)

        #if canImport(Darwin)
            undo.beginUndoGrouping()
            session.toggleViewed("a.txt", advance: false)
            undo.endUndoGrouping()
            #expect(review.collapsed.contains("a.txt"))
            undo.undo()
            #expect(!review.collapsed.contains("a.txt"))
            undo.redo()
        #else
            session.toggleViewed("a.txt", advance: false)
        #endif

        try repo.write("a.txt", "two\n")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()
        #expect(review.viewedStatus("a.txt") == .changedSinceViewed)
        #expect(!review.collapsed.contains("a.txt"))

        session.toggleCollapsed("a.txt")
        await session.apply(RepoChange(worktrees: [repo.main.path]))
        await session.settled()
        #expect(review.collapsed.contains("a.txt"))
    }

    @Test func hidingWhitespaceDropsWhitespaceOnlyChanges() async throws {
        let repo = try await FixtureRepo()
        try await repo.commit("a.txt", "if x {\n  y\n}\n", "a")
        try repo.write("a.txt", "if x {\n    y\n}\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.setBaseOverride("refs/heads/main")
        await session.settled()
        #expect(session.selected?.diff?.files.map(\.diff.path) == ["a.txt"])

        session.toggleWhitespace()
        await session.settled()

        #expect(session.selected?.diff?.files.isEmpty == true)
        #expect(session.selected?.effectiveWhitespace == .ignoreAll)
    }

    @Test func anOpenRequestForANewWorktreeRelistsAndSetsItsBase() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let fresh = try await repo.worktree("fresh", branch: "fresh", from: "origin/main")

        await session.handle(worktree: fresh.path, base: "main")
        await session.settled()

        #expect(session.selected?.id == fresh.path)
        #expect(session.selected?.baseOverride == "refs/heads/main")
    }

    @Test func anOpenRequestForAnUnknownWorktreeLeavesTheSelectionAlone() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()

        await session.handle(worktree: "/nowhere", base: "main")

        #expect(session.selected?.id == repo.main.path)
        #expect(session.selected?.baseOverride == nil)
    }

    @Test func switchingAwayBeforeTheDiffShowsKeepsTheSavedPosition() async throws {
        let repo = try await FixtureRepo()
        let other = try await repo.worktree("other", branch: "other", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let anchor = ScrollAnchor(path: "a.txt", line: 3, offset: 0)
        session.selected?.savedAnchor = anchor

        session.select(other.path)
        session.select(repo.main.path)

        #expect(session.selected?.savedAnchor == anchor)
    }

    @Test func readingAnotherFileIsSavedAtOnce() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "a\n")
        let store = MemoryStore()
        let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await session.open()
        await session.settled()
        let repository = try #require(session.repository)

        session.noteReading("a.txt")
        await session.settled()

        #expect(await store.load(repository).worktrees[repo.main.path]?.currentFile == "a.txt")
    }

    @Test func overrideWhoseRefIsGoneShowsABannerWithAWayBack() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()

        session.setBaseOverride("refs/heads/deleted")
        await session.settled()
        #expect(session.selected?.problem == .overrideGone("deleted"))

        session.setBaseOverride(nil)
        await session.settled()
        #expect(session.selected?.problem == nil)
    }

    @Test func progressAppearsOnlyAfter150Milliseconds() async throws {
        let repo = try await FixtureRepo()
        try repo.write("x.txt", "x\n")
        let git = GatedGit(repo.git, holding: repo.main)
        let clock = ManualClock()
        let session = RepoSession(directory: repo.main, services: services(git, clock: clock))
        await session.open()
        let review = try #require(session.selected)

        await clock.sleepers()
        clock.advance(by: .milliseconds(149))
        #expect(clock.sleeperCount == 1)
        #expect(review.isLoading)
        #expect(!review.showsProgress)
        clock.advance(by: .milliseconds(1))
        while !review.showsProgress { await Task.yield() }
        git.release()
        await review.loaded()

        #expect(!review.showsProgress)
        #expect(review.diff?.files.count == 1)
    }

    @Test func scopePersistsPerWorktree() async throws {
        let repo = try await FixtureRepo()
        let store = MemoryStore()
        let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await session.open()
        session.setScope(.uncommitted)
        await session.settled()

        let reopened = RepoSession(directory: repo.main, services: services(repo.git, store: store))
        await reopened.open()
        #expect(reopened.selected?.scope == .uncommitted)
    }

    /// Reading a branch commit by commit: Next Commit starts at the oldest and goes forward in
    /// time, one commit at a time, and stops at the newest.
    @Test func nextAndPreviousCommitReadTheBranchOneCommitAtATime() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("a", branch: "a", from: "origin/main")
        try await repo.commit("first.txt", "1\n", "first", in: tree)
        try await repo.commit("second.txt", "2\n", "second", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        let review = try #require(session.selected)
        await review.loaded()

        try command("next-commit").run(session)
        await review.loaded()
        #expect(review.diff?.files.map(\.diff.path) == ["first.txt"])
        try command("next-commit").run(session)
        await review.loaded()
        #expect(review.diff?.files.map(\.diff.path) == ["second.txt"])
        #expect(try !command("next-commit").isEnabled(session), "the newest is the end")
        try command("previous-commit").run(session)
        await review.loaded()
        #expect(review.diff?.files.map(\.diff.path) == ["first.txt"])
        // Said where the reader is, the sidebar shown or not.
        #expect(review.rangeSummary == "Commit 1 of 2 · first")
        session.toggleWhitespace()
        await review.loaded()
        #expect(review.rangeSummary == "Commit 1 of 2 · first · Whitespace changes hidden")
        review.showEverything()
        await review.loaded()
        #expect(review.rangeSummary == nil)
        session.close()
    }

    @Test func pickingTheLatestCommitDiffsOnlyThatCommit() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("a", branch: "a", from: "origin/main")
        try await repo.commit("first.txt", "1\n", "first", in: tree)
        try await repo.commit("second.txt", "2\n", "second", in: tree)
        try repo.write("dirty.txt", "x\n", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        let review = try #require(session.selected)
        await review.loaded()
        #expect(review.commitLog?.commits.map(\.subject) == ["second", "first"])

        session.selectLatestCommit()
        await review.loaded()

        #expect(review.diff?.files.map(\.diff.path) == ["second.txt"])
        #expect(review.isShowingLatestCommit && !review.isShowing(.all))

        let log = try #require(review.commitLog)
        session.selectCommits(
            CommitSelection(newest: .workingTree, oldest: try #require(log.ends.last)))
        await review.loaded()

        #expect(review.isShowing(.all))
        #expect(review.diff?.files.map(\.diff.path) == ["dirty.txt", "first.txt", "second.txt"])
    }

    @Test func anotherRangeIsANewDiffButAReloadIsNot() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("a", branch: "a", from: "origin/main")
        try await repo.commit("first.txt", "1\n", "first", in: tree)
        try await repo.commit("second.txt", "2\n", "second", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        let review = try #require(session.selected)
        await review.loaded()
        let opened = review.shownRangeVersion

        review.reloadDiff()
        await review.loaded()
        #expect(review.shownRangeVersion == opened)

        session.selectLatestCommit()
        await review.loaded()
        #expect(review.shownRangeVersion != opened)
    }

    @Test func pickedCommitsARebaseRemovedFallBackToTheScope() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("a", branch: "a", from: "origin/main")
        try await repo.commit("first.txt", "1\n", "first", in: tree)
        try await repo.commit("second.txt", "2\n", "second", in: tree)
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        let review = try #require(session.selected)
        await review.loaded()
        session.selectLatestCommit()
        await review.loaded()
        #expect(review.commitSelection != nil)

        try await repo.run("commit", "-q", "--amend", "-m", "amended", in: tree)
        review.reloadDiff()
        await review.loaded()

        #expect(review.commitSelection == nil)
        #expect(review.isShowing(.all))
        #expect(review.diff?.files.map(\.diff.path) == ["first.txt", "second.txt"])
    }

    @Test func theDiffFollowsTheFilterOnceTypingPauses() async throws {
        let repo = try await FixtureRepo()
        for name in ["src/a.cs", "tests/a_test.cs"] { try repo.write(name, "x\n") }
        let clock = ManualClock()
        let session = RepoSession(directory: repo.main, services: services(repo.git, clock: clock))
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        func shown() -> [String]? { review.content?.review.files.map(\.diff.path) }
        #expect(shown() == ["src/a.cs", "tests/a_test.cs"])

        review.fileFilter = "^tes"
        review.fileFilter = "^test"
        await clock.sleepers()
        #expect(shown() == ["src/a.cs", "tests/a_test.cs"])
        clock.advance(by: WorktreeReview.filterDelay)
        await until { shown() == ["src/a.cs"] }

        review.fileFilter = ""
        #expect(shown() == ["src/a.cs", "tests/a_test.cs"])
    }

    @Test(
        arguments: [
            ("total", "total"), ("  total  ", "total"), ("first line\nsecond", "first line"),
            ("\n", nil), ("   ", nil),
        ] as [(String, String?)])
    func findStartsFromTheSelectionsFirstLine(selection: String, query: String?) {
        #expect(FindState.query(from: selection) == query)
    }

    @Test func theViewModeIsTheSameForEveryWorktree() async throws {
        let repo = try await FixtureRepo()
        _ = try await repo.worktree("a", branch: "a", from: "origin/main")
        let services = services(repo.git)
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        session.toggleMode()

        #expect(session.reviews.allSatisfy { $0.mode == .split })
        #expect(services.settings.layoutMode == .split)
    }

    @Test func positionAndAdjacentSelectionFollowTheSortedList() async throws {
        let repo = try await FixtureRepo()
        _ = try await repo.worktree("a", branch: "a", from: "origin/main")
        _ = try await repo.worktree("b", branch: "b", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.sort = .name

        session.select(position: 2)
        #expect(session.selected?.worktree.name == "wt-b")
        session.selectAdjacent(1)
        #expect(session.selected?.worktree.name == "repo")
        session.selectAdjacent(-1)
        #expect(session.selected?.worktree.name == "wt-b")
    }
}

/// Runs the next `git status` at once but holds its answer until released, so it arrives after
/// a newer one.
private final class HoldsNextStatus: GitClient, Sendable {
    private struct State {
        var armed = false
        var holding: CheckedContinuation<Void, Never>?
        var watcher: CheckedContinuation<Void, Never>?
        var released = false
    }

    private let inner: any GitClient
    private let state = Mutex(State())

    init(_ inner: any GitClient) {
        self.inner = inner
    }

    func arm() {
        state.withLock { $0.armed = true }
    }

    /// Returns once a status answer is being held.
    func held() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state in
                if state.holding != nil { return true }
                state.watcher = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }

    func release() {
        let holding = state.withLock { state in
            state.released = true
            defer { state.holding = nil }
            return state.holding
        }
        holding?.resume()
    }

    func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError) -> Data
    {
        let result = await Result { () async throws(GitError) -> Data in
            try await inner.run(arguments, in: directory, input: input)
        }
        let holds =
            arguments.first == "status"
            && state.withLock { state in
                defer { state.armed = false }
                return state.armed
            }
        if holds {
            await withCheckedContinuation { continuation in
                let (watcher, released) = state.withLock { state in
                    state.holding = continuation
                    defer { state.watcher = nil }
                    return (state.watcher, state.released)
                }
                watcher?.resume()
                if released { continuation.resume() }
            }
        }
        return try result.get()
    }
}

/// A state store whose next save waits until released, to ask for more while one is written.
private actor HoldingStore: StateStore {
    private let inner = MemoryStore()
    private(set) var saves = 0
    private var holding = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var watcher: CheckedContinuation<Void, Never>?

    func seed(_ state: RepoState, for repository: Repository) async {
        await inner.seed(state, for: repository)
    }

    func hold() { holding = true }

    func held() async {
        if waiting != nil { return }
        await withCheckedContinuation { watcher = $0 }
    }

    func release() {
        holding = false
        waiting?.resume()
        waiting = nil
    }

    func load(_ repository: Repository) async -> RepoState { await inner.load(repository) }

    func loadProblem(for repository: Repository) -> String? { nil }

    @discardableResult
    func save(_ state: RepoState, for repository: Repository) async -> String? {
        if holding {
            await withCheckedContinuation { continuation in
                waiting = continuation
                watcher?.resume()
                watcher = nil
            }
        }
        saves += 1
        return await inner.save(state, for: repository)
    }

    func keepSeen(_ text: String, id: String, for repository: Repository) async {}
    func seen(_ id: String, for repository: Repository) async -> String? { nil }
    func recentRepositories() async -> [URL] { [] }
    func noteOpened(_ directory: URL) async {}
    func clearRecent() async {}
}

private actor FailingStore: StateStore {
    func load(_ repository: Repository) -> RepoState { RepoState() }
    func loadProblem(for repository: Repository) -> String? { nil }
    @discardableResult
    func save(_ state: RepoState, for repository: Repository) -> String? { "disk full" }
    func keepSeen(_ text: String, id: String, for repository: Repository) {}
    func seen(_ id: String, for repository: Repository) -> String? { nil }
    func recentRepositories() -> [URL] { [] }
    func noteOpened(_ directory: URL) {}
    func clearRecent() {}
}
