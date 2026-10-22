import Foundation
import GitKit
import TestSupport
import Testing

@testable import SeamCore

private let environment = ProcessInfo.processInfo.environment

/// SPEC §5.2 real-repo check: a pinned commit of a stacked branch, its expected parent, base
/// and committed-scope `files additions deletions`. `make test-all` passes them from local.mk,
/// which stays out of git; the suite skips without them.
@Suite(.enabled(if: !(environment["SEAM_REAL_REPO"] ?? "").isEmpty))
struct RealRepoTests {
    @Test func aStackedBranchIsReviewedAgainstItsParent() async throws {
        func value(_ name: String) throws -> String {
            let value = try #require(environment["SEAM_REAL_\(name)"], "SEAM_REAL_\(name) not set")
            try #require(!value.isEmpty, "SEAM_REAL_\(name) is empty")
            return value
        }
        let worktree = URL(fileURLWithPath: try value("REPO"), isDirectory: true)
        let parent = try value("PARENT")
        let stat = try value("STAT").split(separator: " ").compactMap { Int($0) }
        try #require(stat.count == 3, "SEAM_REAL_STAT is 'files additions deletions'")
        let git = CLIGitClient()
        guard (try? await git.run(["rev-parse", "--verify", "-q", parent], in: worktree)) != nil
        else {
            Issue.record("parent ref \(parent) no longer exists; update local.mk")
            return
        }

        let detection = try await BaseDetector(git: git).detect(
            in: worktree, at: .commit(try value("COMMIT"), branch: try value("BRANCH")))
        let review = try await ReviewDiffBuilder(git: git).build(
            worktree: worktree, base: detection.base, head: detection.head, scope: .committed)

        #expect(detection.parent?.ref == parent)
        #expect(detection.base.hasPrefix(try value("BASE")))
        #expect([review.files.count, review.additions, review.deletions] == stat)
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
