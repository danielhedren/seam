import Foundation
import GitKit

/// A parent that looks merged (SPEC §5.4): squash-merged branches never reach main, so detection
/// keeps choosing them and the diff silently shrinks to the commits after them.
public struct StaleParent: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The parent's upstream was deleted after its pull request merged.
        case upstreamGone
        /// A local-only parent whose tip is already in `suggestion`.
        case containedIn
    }

    public var parent: String
    var reason: Reason
    /// The base to offer instead: the default base, or another candidate.
    public var suggestion: ParentCandidate

    /// Nil when the parent is a remote ref, has a live upstream, or shows no sign of merging.
    public static func check(_ detection: BaseDetection, in worktree: URL, git: any GitClient)
        async throws(GitError) -> StaleParent?
    {
        guard let parent = detection.parent, parent.ref.hasPrefix(RefName.heads),
            let suggestion = detection.candidates.first(where: {
                $0.isDefaultBase && $0.ref != parent.ref
            })
                ?? detection.candidates.first(where: { $0.ref != parent.ref })
        else { return nil }
        let tracking = try await git.string(
            ["for-each-ref", "--format=%(upstream)%00%(upstream:track)", parent.ref], in: worktree
        ).trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
        if tracking.count == 2, !tracking[0].isEmpty {
            guard tracking[1] == "[gone]" else { return nil }
            return StaleParent(parent: parent.name, reason: .upstreamGone, suggestion: suggestion)
        }
        let remoteCopy = try await git.optionalLine(
            ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" + parent.name], in: worktree
        )
        guard remoteCopy == nil else { return nil }
        // Only the default base or a remote ref proves a merge: a sibling branch cut from the same
        // local parent also contains its tip.
        for candidate in detection.candidates
        where candidate.ref != parent.ref && (candidate.isDefaultBase || candidate.isRemote) {
            let contained = try await git.optionalLine(
                ["merge-base", "--is-ancestor", parent.tip, candidate.tip], in: worktree)
            if contained != nil {
                return StaleParent(parent: parent.name, reason: .containedIn, suggestion: candidate)
            }
        }
        return nil
    }
}
