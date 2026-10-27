import Foundation
import Observation
import ReviewTestSupport
import SeamCore
import TestSupport
import Testing

@testable import ReviewModel

@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveReloadTests {
    /// SPEC §14 M2: an edit in the worktree reaches the diff within 1 s, through real FSEvents.
    @Test func editingAFileUpdatesTheDiff() async throws {
        let repo = try await FixtureRepo()
        let services = SeamServices(
            git: repo.git, watcher: SystemFileWatcher(), clock: ContinuousClock(),
            store: MemoryStore(), threads: scratchThreadStore(), settings: testSettings())
        let session = RepoSession(directory: repo.main, services: services)
        await session.open()
        await session.settled()
        let review = try #require(session.selected)
        let version = review.diffVersion

        let clock = ContinuousClock()
        let start = clock.now
        try repo.write("README.md", "fixture\nedited\n")
        await until { review.diffVersion > version }
        let elapsed = clock.now - start

        #expect(review.diff?.files.map(\.diff.path) == ["README.md"])
        if ProcessInfo.processInfo.environment["SEAM_BENCH"] != nil {
            #expect(elapsed < budget(.seconds(1)), "reload took \(elapsed)")
        }
        session.close()
    }
}
