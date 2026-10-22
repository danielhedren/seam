import Foundation
import SeamCore
import TestSupport
import Testing

@testable import Features

@MainActor
struct WorktreeSwitcherTests {
    @Test func matchesWorktreeAndBranchNamesBestFirst() async throws {
        let repo = try await FixtureRepo()
        _ = try await repo.worktree("orders", branch: "feat/delivery", from: "origin/main")
        _ = try await repo.worktree("delivery-fix", branch: "fix", from: "origin/main")
        let session = RepoSession(directory: repo.main, services: services(repo.git))
        await session.open()

        let names = { (query: String) in
            WorktreeSwitcher.matches(query, in: session.sortedReviews).map(\.worktree.name)
        }
        #expect(names("delivery") == ["wt-delivery-fix", "wt-orders"])
        #expect(names("") == session.sortedReviews.map(\.worktree.name))
        #expect(names("zzz").isEmpty)
    }

    @Test func arrowsMoveTheHighlightAndStopAtTheEnds() {
        let ids = ["a", "b", "c"]
        #expect(WorktreeSwitcher.moved("a", by: 1, in: ids) == "b")
        #expect(WorktreeSwitcher.moved("c", by: 1, in: ids) == "c")
        #expect(WorktreeSwitcher.moved("a", by: -1, in: ids) == "a")
        #expect(WorktreeSwitcher.moved("gone", by: 1, in: ids) == "b")
        #expect(WorktreeSwitcher.moved(nil, by: 1, in: []) == nil)
    }
}
