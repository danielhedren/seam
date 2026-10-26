import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

/// "1\n2\n…", with some lines replaced.
package func numberedLines(_ range: ClosedRange<Int>, replacing: [Int: String] = [:]) -> String {
    range.map { replacing[$0] ?? "\($0)" }.joined(separator: "\n") + "\n"
}

/// a.txt's added and removed lines as the review shows them.
@MainActor
package func changedLines(_ review: WorktreeReview) -> [String]? {
    review.content?.review.files.first { $0.diff.path == "a.txt" }?.diff.hunks
        .flatMap(\.lines).filter { $0.kind != .context }.map(\.text)
}

/// Marks a.txt viewed, then changes line 10 the way an agent would.
@MainActor
package func viewedThenChanged(_ repo: FixtureRepo, store: MemoryStore) async throws
    -> (RepoSession, WorktreeReview)
{
    let session = RepoSession(directory: repo.main, services: services(repo.git, store: store))
    await session.open()
    await session.settled()
    let review = try #require(session.selected)
    review.currentFile = "a.txt"
    session.toggleViewed("a.txt", advance: false)
    await session.settled()
    try repo.write("a.txt", numberedLines(1...20, replacing: [10: "ten"]))
    await session.apply(RepoChange(worktrees: [repo.main.path]))
    await session.settled()
    return (session, review)
}
