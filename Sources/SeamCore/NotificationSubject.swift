/// What the reader opened in Seam, and which notifications that answers (SPEC §7.10). Ids are
/// `<worktree>|<what>` as `NotificationText` writes them; a listed pull request's is keyed by
/// the repo's main worktree, so it's told apart by its `pr-` prefix.
public enum NotificationSubject: Equatable, Sendable {
    /// A Seam thread, opened in its worktree's diff.
    case thread(worktree: String, id: String)
    /// A worktree, selected: its pull request's news.
    case worktree(String)
    /// A pull request of the repo's list, opened.
    case pullRequest(repo: String, number: Int)

    public func covers(_ id: String) -> Bool {
        switch self {
        case .thread(let worktree, let thread):
            return id == "\(worktree)|agent-\(thread)"
        case .worktree(let worktree):
            guard id.hasPrefix("\(worktree)|") else { return false }
            let what = id.dropFirst(worktree.count + 1)
            return !what.hasPrefix("agent-") && !what.hasPrefix("pr-")
        case .pullRequest(let repo, let number):
            return id == "\(repo)|pr-\(number)" || id.hasPrefix("\(repo)|pr-\(number)-")
        }
    }
}
