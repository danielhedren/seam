import Foundation
import GitKit

/// Every branch and remote ref of a repo, which all its worktrees share (refs live in the common
/// git dir), so one listing serves a whole refresh of the worktree list.
public struct RefSnapshot: Sendable {
    struct Row: Sendable {
        var ref: String
        var tip: String
        var upstream: String
        var committerDate: Int
    }

    var refs: [String: Row] = [:]
    var symbolic: [String: String] = [:]
    var remotes: [String] = []

    public static func load(in directory: URL, git: any GitClient) async throws(GitError)
        -> RefSnapshot
    {
        let format = "%(refname)%00%(objectname)%00%(upstream)%00%(committerdate:unix)%00%(symref)"
        let output = try await git.string(
            ["for-each-ref", "--format=\(format)", "refs/heads", "refs/remotes"], in: directory)
        var snapshot = RefSnapshot()
        for row in output.split(separator: "\n") {
            let fields = row.split(separator: "\0", omittingEmptySubsequences: false).map(
                String.init)
            guard fields.count == 5 else { continue }
            if !fields[4].isEmpty {
                snapshot.symbolic[fields[0]] = fields[4]
                continue
            }
            snapshot.refs[fields[0]] = Row(
                ref: fields[0], tip: fields[1], upstream: fields[2],
                committerDate: Int(fields[3]) ?? 0)
        }
        snapshot.remotes = try await git.string(["remote"], in: directory)
            .split(separator: "\n").map(String.init)
        return snapshot
    }
}
