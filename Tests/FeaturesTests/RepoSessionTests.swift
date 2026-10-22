import AppKit
import DiffView
import Foundation
import GitKit
import SeamCore
import TestSupport
import Testing

@testable import Features

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
        #expect(session.sortedReviews.map(\.worktree.name) == ["repo", "wt-feature"])
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
        #expect(session.reviews.first { $0.id == other.path }?.activity != nil)
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

    @Test func closingWhileOpeningLeavesNothingWatching() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))

        let opening = Task { await session.open() }
        session.close()
        await opening.value

        #expect(!session.isWatching)
        #expect(session.state == .opening)
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
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        review.currentFile = "a.txt"

        undo.beginUndoGrouping()
        session.toggleViewed()
        undo.endUndoGrouping()
        #expect(review.viewedStatus("a.txt") == .viewed)
        #expect(review.currentFile == "b.txt")
        undo.undo()
        #expect(review.viewedStatus("a.txt") == .unviewed)
        undo.redo()
        #expect(review.viewedStatus("a.txt") == .viewed)
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

    @Test func openInEditorPassesTheWorktreePathAndReadingLine() async throws {
        let repo = try await FixtureRepo()
        try repo.write("dir with space/it's.txt", "one\ntwo\n")
        let launcher = FakeLauncher()
        var services = services(repo.git)
        services.launcher = launcher
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        session.diff.view = view
        view.show(try #require(session.selected?.content), position: .top)

        session.openInEditor(EditorCommand(template: "ed +{line} {path}"))

        let path = repo.main.appending(path: "dir with space/it's.txt").path
        #expect(await launcher.next() == "ed +1 " + EditorCommand.quoted(path))
    }

    @Test func aFailingEditorShowsItsMessageAsABanner() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let launcher = FakeLauncher()
        await launcher.fail(with: "zed: command not found")
        var services = services(repo.git)
        services.launcher = launcher
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        session.diff.view = view
        view.show(try #require(session.selected?.content), position: .top)

        session.openInEditor()
        _ = await launcher.next()
        let review = try #require(session.selected)
        await until { review.problem != nil }

        #expect(review.problem == .editorFailed("zed: command not found"))
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

    @Test func fileActionsCopyPathsAndFollowTheFilesState() async throws {
        let repo = try await FixtureRepo()
        try repo.write("dir/a.txt", "a\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("seam-tests-\(UUID())"))

        session.copyPath("dir/a.txt", relative: true, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "dir/a.txt")
        session.copyPath("dir/a.txt", relative: false, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == repo.main.appending(path: "dir/a.txt").path)

        let titles = {
            FileActions.actions(for: "dir/a.txt", in: session).flatMap { $0.map(\.title) }
        }
        #expect(titles().contains("Mark as Viewed"))
        session.toggleViewed("dir/a.txt", advance: false)
        #expect(titles().contains("Mark as Not Viewed"))
        #expect(titles().contains("Expand"))
        session.toggleCollapsed("dir/a.txt")
        #expect(titles().contains("Collapse"))
        pasteboard.releaseGlobally()
    }

    @Test func viewedFilesFoldAwayAndOpenAgainWhenTheyChange() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        let undo = UndoManager()
        undo.groupsByEvent = false
        session.undoManager = undo
        await session.open()
        await session.settled()
        let review = try #require(session.selected)

        undo.beginUndoGrouping()
        session.toggleViewed("a.txt", advance: false)
        undo.endUndoGrouping()
        #expect(review.collapsed.contains("a.txt"))
        undo.undo()
        #expect(!review.collapsed.contains("a.txt"))
        undo.redo()

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

    @Test func aQuerySetBeforeTheFindBarExistsStillSearches() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "alpha\nbeta\nalpha\n")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()
        let view = DiffScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        var totals: [Int] = []
        view.onSearchResult = { _, total in totals.append(total) }
        view.show(try #require(session.selected?.content), position: .top)
        session.diff.view = view

        session.findQuery = "alpha"

        #expect(totals.last == 2)
    }

    @Test(
        arguments: [
            ("total", "total"), ("  total  ", "total"), ("first line\nsecond", "first line"),
            ("\n", nil), ("   ", nil),
        ] as [(String, String?)])
    func findStartsFromTheSelectionsFirstLine(selection: String, query: String?) {
        #expect(RepoSession.findQuery(from: selection) == query)
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

@Suite struct FileTreeTests {
    private let paths = [
        "src/Orders.Service/Delivery/A.cs", "src/Orders.Service/Delivery/B.cs",
        "src/Orders.Service/C.cs",
        "README.md",
    ]

    @Test func singleChildDirectoriesAreCompacted() {
        let rows = FileTree.rows(paths)
        #expect(
            rows.map(\.name) == [
                "src/Orders.Service", "Delivery", "A.cs", "B.cs", "C.cs", "README.md",
            ])
        #expect(rows.map(\.depth) == [0, 1, 2, 2, 1, 0])
        #expect(rows[2].id == "src/Orders.Service/Delivery/A.cs")
        #expect(rows[2].kind == .file(0))
    }

    @Test func collapsedDirectoriesHideTheirContents() {
        let rows = FileTree.rows(paths, collapsed: ["src/Orders.Service/Delivery/"])
        #expect(rows.map(\.name) == ["src/Orders.Service", "Delivery", "C.cs", "README.md"])
        #expect(rows[1].kind == .directory(isExpanded: false))
    }

    @Test func filterMatchesPathsAndIgnoresCollapsing() {
        let rows = FileTree.rows(paths, collapsed: ["src/Orders.Service/"], filter: "delivery/b")
        #expect(rows.map(\.name) == ["src/Orders.Service/Delivery", "B.cs"])
    }

    @Test func aCaretTermLeavesMatchingPathsOutAndKeepsTheTreeAsItWas() {
        let rows = FileTree.rows(
            paths, collapsed: ["src/Orders.Service/Delivery/"], filter: "^c.cs")
        // One child left, so the chain compacts; it stays collapsed as the reader left it.
        #expect(rows.map(\.name) == ["src/Orders.Service/Delivery", "README.md"])
        #expect(rows.first?.kind == .directory(isExpanded: false))
        #expect(
            FileTree.rows(paths, filter: "orders ^delivery").map(\.name) == [
                "src/Orders.Service", "C.cs",
            ])
    }

    @Test(arguments: [
        ("", "src/Tests/A.cs", true), ("tests", "src/Tests/A.cs", true),
        ("^test", "src/Tests/A.cs", false), ("^test", "src/A.cs", true),
        ("src ^test", "src/A.cs", true), ("src ^test", "lib/A.cs", false), ("^", "src/A.cs", true),
    ])
    func filterTermsAllMatchAndCaretTermsNone(filter: String, path: String, kept: Bool) {
        #expect(FileFilter(filter).matches(path) == kept)
    }

    @Test func generatedFilesSitUnderTheirOwnClosedHeading() {
        let paths = ["src/a.cs", "src/Generated/b.cs", "package-lock.json"]
        let closed = FileTree.rows(paths, generated: [1, 2])
        #expect(closed.map(\.name) == ["src", "a.cs", "Generated"])
        #expect(closed.last?.kind == .generated(count: 2, isExpanded: false))
        let open = FileTree.rows(paths, generated: [1, 2], showsGenerated: true)
        #expect(open.suffix(2).map(\.name) == ["src/Generated/b.cs", "package-lock.json"])
    }

    @Test func aPathListedTwiceGetsDistinctRowIDs() {
        let rows = FileTree.rows(["link", "link"], flat: true)
        #expect(Set(rows.map(\.id)).count == 2)
        #expect(rows.map(\.name) == ["link", "link"])
        #expect(Set(FileTree.rows(["a/link", "a/link"]).map(\.id)).count == 3)
    }

    @Test func flatListShowsFullPathsInReviewOrder() {
        #expect(FileTree.rows(paths, flat: true).map(\.name) == paths)
    }
}

@Suite struct FuzzyMatchTests {
    @Test func subsequencesMatchAndBetterMatchesScoreHigher() throws {
        let exact = try #require(FuzzyMatch.score("1894", in: "ticket-1894-remove-preview"))
        let scattered = try #require(FuzzyMatch.score("1894", in: "ticket-1872-preview-9-4"))
        #expect(exact > scattered)
        #expect(FuzzyMatch.score("xyz", in: "ticket-1894") == nil)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }
}

@Suite struct LaunchArgumentTests {
    @Test(
        arguments: [
            (["Seam", "/repo"], "/repo"),
            (["Seam", "-NSDocumentRevisionsDebugMode", "YES", "/repo"], "/repo"),
            (["Seam", "-NSDocumentRevisionsDebugMode", "YES"], nil),
            (
                [
                    "Seam", "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows",
                    "NO", "/r",
                ], "/r"
            ),
            (["Seam"], nil),
        ] as [([String], String?)])
    func defaultsPairsAreNotTakenForAPath(arguments: [String], expected: String?) {
        #expect(WelcomeView.launchPath(arguments) == expected)
    }
}

@Suite struct ShellLauncherTests {
    private let launcher = ShellLauncher(shell: URL(fileURLWithPath: "/bin/sh"))

    @Test func aFailingCommandReportsWhatItPrinted() async {
        await #expect(throws: LaunchFailed(message: "no such editor")) {
            try await launcher.run("echo 'no such editor' >&2; exit 3")
        }
    }

    @Test func aChattyCommandThatSucceedsIsFine() async throws {
        try await launcher.run("head -c 200000 /dev/zero >&2")
    }

    @Test func aMissingCommandSaysSoWithoutTheShellsNoise() async {
        await #expect(
            throws: LaunchFailed(
                message:
                    "seam-no-such-editor isn't installed or isn't on your PATH. Choose your editor in Settings."
            )
        ) {
            try await launcher.run("seam-no-such-editor '/a b':1")
        }
    }

    @Test func aPresetMissingFromPathRunsTheToolInsideItsApp() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let tool = app.appending(path: "Contents/MacOS/cli")
        let bin = app.appending(path: "bin")
        defer { try? FileManager.default.removeItem(at: app) }
        for executable in [tool, bin.appending(path: "zed")] {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(
                FileManager.default.createFile(
                    atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
                    attributes: [.posixPermissions: 0o755]))
        }
        var launcher = launcher
        launcher.locateApp = { $0 == "dev.zed.Zed" ? app : nil }
        #expect(
            launcher.resolve("zed '/w/a.swift':3", path: "/nowhere")
                == EditorCommand.quoted(tool.path) + " '/w/a.swift':3")
        #expect(
            launcher.resolve("zed '/w/a.swift':3", path: "/nowhere:" + bin.path)
                == "zed '/w/a.swift':3")
    }
}

@Suite struct EditorCommandTests {
    @Test func theDefaultIsTheFirstInstalledPreset() {
        #expect(
            EditorCommand.installedDefault {
                $0 == "com.microsoft.VSCode" ? URL(filePath: "/A") : nil
            }
                == "code -g {path}:{line}")
        #expect(EditorCommand.installedDefault { _ in nil } == EditorCommand.zed)
    }

    @Test func pathsAreQuotedSoSpacesAndQuotesStayOneArgument() {
        let line = EditorCommand(template: "code -g {path}:{line}").commandLine(
            path: "/w/a b/it's.swift", line: 42)
        #expect(line == "code -g '/w/a b/it'\\''s.swift':42")
    }
}
