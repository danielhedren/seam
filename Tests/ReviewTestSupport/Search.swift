import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// A session on `repo`, opened and settled, with its selected worktree.
@MainActor
package func openedSession(_ repo: FixtureRepo, clock: ManualClock = ManualClock()) async throws
    -> (RepoSession, WorktreeReview)
{
    let session = RepoSession(directory: repo.main, services: services(repo.git, clock: clock))
    await session.open()
    await session.settled()
    return (session, try #require(session.selected))
}

extension WorktreeReview {
    /// Types a search query and lets the pause pass.
    package func searchSettled(_ text: String, clock: ManualClock) async {
        navigator = .search
        search = TextQuery(text)
        await clock.sleepers()
        clock.advance(by: WorktreeReview.filterDelay)
        await until { self.appliedSearch.text == text }
    }
}
