import Foundation
import GitKit

/// The commit a review diffs against: the detected base, or the merge base with a parent the
/// reader chose in the base picker (SPEC §5.3).
public struct ReviewBase: Equatable, Sendable {
    public var commit: String
    /// Commits on HEAD since `commit`; nil for the detected base, whose count detection has.
    public var commitCount: Int?

    /// Nil when the chosen parent no longer resolves or shares no history with HEAD.
    public static func resolve(
        detection: BaseDetection, override: String?, in worktree: URL, git: any GitClient
    ) async throws(GitError) -> ReviewBase? {
        guard let override else { return ReviewBase(commit: detection.base) }
        let detector = BaseDetector(git: git)
        guard let commit = try await detector.base(forParent: override, in: worktree) else {
            return nil
        }
        return ReviewBase(
            commit: commit, commitCount: try await detector.commitCount(since: commit, in: worktree)
        )
    }
}
