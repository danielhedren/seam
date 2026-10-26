import Foundation
import GitKit
import ReviewTestSupport
import SeamCore
import Testing

@testable import ReviewModel

private let environment = ProcessInfo.processInfo.environment

/// SPEC §7.8 against the real repo and the user's own gh, read-only. Run with `make test-github`;
/// it needs the network and a gh login, so `make check` never runs it.
@MainActor
@Suite(
    .enabled(
        if: environment["SEAM_REAL_GITHUB"] != nil
            && !(environment["SEAM_REAL_REPO"] ?? "").isEmpty),
    .timeLimit(.minutes(1)))
struct RealGitHubTests {
    @Test func theRealReposWorktreesShowTheirPullRequests() async throws {
        let worktree = URL(fileURLWithPath: try #require(environment["SEAM_REAL_REPO"]))
        let services = SeamServices(
            git: CLIGitClient(), watcher: SilentWatcher(), clock: ContinuousClock(),
            store: MemoryStore(), threads: scratchThreadStore(), settings: testSettings(),
            github: .live())
        let session = RepoSession(directory: worktree, services: services)
        let clock = ContinuousClock()
        let start = clock.now
        await session.open()
        await session.rowsLoaded()
        let rows = clock.now - start
        await until { session.pullRequests?.saved.read != nil }
        let shownAt = clock.now - start
        await session.pullRequests?.idle()
        let read = clock.now - start
        await session.settled()
        defer { session.close() }

        #expect(session.pullRequests?.status == .ready)
        let shown = session.sortedReviews.compactMap { review in
            review.pullRequest.map { (review, $0) }
        }
        #expect(!shown.isEmpty, "some worktree has a pull request")
        // Numbers and markers only: the attachment stays on this machine.
        let summary = shown.map { review, pullRequest in
            "#\(pullRequest.number) \(pullRequest.marker) ciFailed=\(pullRequest.ciFailed) "
                + "checks=\(pullRequest.checks.passed)/\(pullRequest.checks.failed)/"
                + "\(pullRequest.checks.pending) unpushed=\(review.unpushedCount ?? 0) "
                + "base=\(review.pullRequests?.baseRef(for: review.worktree.branch ?? "") ?? "-")"
        }
        let timing = "rows \(rows), first markers \(shownAt), all read \(read)"
        // SPEC §7.9: the fixed thread query runs against GitHub itself, not only the fake.
        let repo = try #require(session.pullRequests?.repo)
        var threads: [String] = []
        for (review, pullRequest) in shown {
            let read = try await services.github.client.reviewThreads(pullRequest.number, in: repo)
            let placed = review.placedThreads.filter { $0.thread.source == .gitHub }
            threads.append(
                "#\(pullRequest.number) threads=\(read.count) "
                    + "comments=\(read.map(\.comments.count).reduce(0, +)) "
                    + "inDiff=\(placed.count { $0.isInDiff }) shown=\(placed.count)")
        }
        Attachment.record(
            ([timing] + summary + threads).joined(separator: "\n"), named: "pull-requests.txt")
        for (_, pullRequest) in shown where pullRequest.state == .open {
            #expect(!pullRequest.url.isEmpty)
        }
    }
}
