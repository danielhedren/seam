import Foundation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// The palette's, the switcher's and Threads' lists, ordered without a window.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ListTests {
    @Test func paletteJumpsToWorktreesWithTheirShortcutsAndShowsWhatIsOn() async throws {
        let repo = try await FixtureRepo()
        let tree = try await repo.worktree("feature", branch: "feature", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        session.select(tree.path)
        await session.settled()

        let entries = session.paletteEntries()

        #expect(!entries.contains { $0.id.hasPrefix("worktree-") })
        let jump = try #require(entries.first { $0.id == "go:" + tree.path })
        #expect(jump.title == "Go to \(tree.lastPathComponent)")
        #expect(jump.shortcut == "⌘2")
        #expect(entries.first { $0.id == "scope-all" }?.isOn == true)
        #expect(entries.first { $0.id == "scope-all" }?.menu == "Review")
        #expect(entries.first { $0.id == "find" }?.shortcut == "⌘F")
        #expect(entries.first { $0.id == "filter-files" }?.shortcut == "")
    }

    @Test func matchesWorktreeAndBranchNamesBestFirst() async throws {
        let repo = try await FixtureRepo()
        _ = try await repo.worktree("orders", branch: "feat/delivery", from: "origin/main")
        _ = try await repo.worktree("delivery-fix", branch: "fix", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()

        let names = { (query: String) in
            session.worktrees(matching: query).map(\.worktree.name)
        }
        #expect(names("delivery") == ["wt-delivery-fix", "wt-orders"])
        #expect(names("") == session.sortedReviews.map(\.worktree.name))
        #expect(names("zzz").isEmpty)
    }

    @Test func thePalettesQueryRanksTheBestMatchFirst() async throws {
        let repo = try await FixtureRepo()
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()
        await session.settled()

        #expect(session.paletteEntries(matching: "find").first?.id == "find")
        #expect(session.paletteEntries(matching: "zzzz").isEmpty)
        session.close()
    }

    /// Threads' file groups leave out what Awaiting You already shows.
    @Test func threadGroupsFollowTheFilesAndLeaveOutTheExcluded() async throws {
        let repo = try await FixtureRepo()
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "two\n")
        let (session, review, _) = await threadSession(repo)
        let reviewed = try #require(review)
        for path in ["a.txt", "b.txt"] {
            session.draft = ThreadDraft(
                worktree: reviewed.id,
                anchor: try #require(reviewed.anchor(path: path, side: .new, lines: 1...1)))
            await session.post("Why?")
            session.closeThread()
        }
        let first = try #require(reviewed.placedThreads.first?.id)

        #expect(reviewed.threadGroups().map(\.path) == ["a.txt", "b.txt"])
        #expect(reviewed.threadGroups(excluding: [first]).map(\.path) == ["b.txt"])
        session.close()
    }
}
