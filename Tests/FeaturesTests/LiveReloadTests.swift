import Foundation
import Observation
import SeamCore
import TestSupport
import Testing

@testable import Features

/// Returns once `condition` holds, re-checking whenever an observed property changes.
@MainActor
func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct LiveReloadTests {
    /// SPEC §14 M2: an edit in the worktree reaches the diff within 1 s, through real FSEvents.
    @Test func editingAFileUpdatesTheDiff() async throws {
        let repo = try await FixtureRepo()
        let services = SeamServices(
            git: repo.git, watcher: FSEventsWatcher(), clock: ContinuousClock(),
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
            #expect(elapsed < .seconds(1), "reload took \(elapsed)")
        }
        session.close()
    }
}
