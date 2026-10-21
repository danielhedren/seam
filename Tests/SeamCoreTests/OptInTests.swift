import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

private let environment = ProcessInfo.processInfo.environment

/// SPEC §5.2 real-repo check. Run with `make test-all`; skipped when the worktree or its old
/// parent ref is gone.
@Suite(.enabled(if: environment["SEAM_REAL_REPO"] != nil))
struct RealRepoTests {
    @Test func aStackedBranchIsReviewedAgainstItsParent() async throws {
        let path = try #require(environment["SEAM_REAL_REPO"])
        let worktree = URL(fileURLWithPath: path, isDirectory: true)
        let git = CLIGitClient()
        let parent = "refs/remotes/origin/feat/a"
        guard (try? await git.run(["rev-parse", "--verify", "-q", parent], in: worktree)) != nil
        else {
            Issue.record("parent ref \(parent) no longer exists; update the fixture")
            return
        }

        let detection = try await BaseDetector(git: git).detect(
            in: worktree, at: .commit("9f8e7d6c5", branch: "feat/b"))
        let review = try await ReviewDiffBuilder(git: git).build(
            worktree: worktree, base: detection.base, head: detection.head, scope: .committed)

        #expect(detection.parent?.name == "origin/feat/a")
        #expect(detection.base.hasPrefix("4a1b2c3d4"))
        #expect(review.files.count == 19)
        #expect(review.additions == 456)
        #expect(review.deletions == 950)
    }
}

/// SPEC §8.7 detection budget on a generated repo with 400 refs.
@Suite(.enabled(if: environment["SEAM_BENCH"] != nil))
struct DetectionBenchmarkTests {
    @Test func detectionWithManyRefsStaysWithinBudget() async throws {
        let repo = try await FixtureRepo()
        for index in 0..<40 {
            try await repo.commit("main.txt", "\(index)\n", "main \(index)")
        }
        let input = (0..<400).map { "create refs/remotes/origin/branch-\($0) HEAD~\($0 % 40)" }
            .joined(separator: "\n")
        _ = try await repo.git.run(
            ["update-ref", "--stdin"], in: repo.main, input: Data((input + "\n").utf8))
        let feature = try await repo.worktree("feature", branch: "feature", from: "HEAD~5")
        try await repo.commit("f.txt", "f\n", "f", in: feature)
        let detector = BaseDetector(git: repo.git)

        let clock = ContinuousClock()
        _ = try await detector.detect(in: feature)
        let elapsed = try await clock.measure { _ = try await detector.detect(in: feature) }

        #expect(elapsed < .milliseconds(150), "detection took \(elapsed)")
    }
}
