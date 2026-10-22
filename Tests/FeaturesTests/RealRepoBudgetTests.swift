import Foundation
import GitKit
import SeamCore
import Testing

@testable import Features

private let environment = ProcessInfo.processInfo.environment

/// SPEC §8.7 budgets on the real repo. Run with `make test-all`.
@MainActor
@Suite(
    .enabled(if: environment["SEAM_BENCH"] != nil && !(environment["SEAM_REAL_REPO"] ?? "").isEmpty)
)
struct RealRepoBudgetTests {
    @Test func worktreeListIsReadyWithinOneSecondAndSwitchingLoadsWithin200ms() async throws {
        let worktree = URL(fileURLWithPath: try #require(environment["SEAM_REAL_REPO"]))
        let services = SeamServices(
            git: CLIGitClient(), watcher: SilentWatcher(), clock: ContinuousClock(),
            store: MemoryStore(), threads: scratchThreadStore(), settings: testSettings())
        let session = RepoSession(directory: worktree, services: services)
        let clock = ContinuousClock()

        let open = await clock.measure {
            await session.open()
            await session.rowsLoaded()
        }
        await session.settled()
        let other = try #require(
            session.sortedReviews.first { $0.id != session.selectedID && !$0.worktree.isMissing })
        let target = try #require(session.selected?.id)
        session.select(other.id)
        await session.settled()
        let switching = await clock.measure {
            session.select(target)
            await session.settled()
        }

        #expect(session.reviews.allSatisfy { $0.worktree.isMissing || $0.activity != nil })
        #expect(
            open < .seconds(1), "worktree list took \(open) for \(session.reviews.count) worktrees")
        #expect(switching < .milliseconds(200), "switching took \(switching)")
    }
}
