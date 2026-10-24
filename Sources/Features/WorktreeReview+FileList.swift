import SeamCore

/// The file list's rows per diff and list options. The list follows the diff's current file,
/// so its body runs on every scroll; building the tree each time would redo it for nothing.
final class FileListCache {
    struct Key: Equatable {
        var diffVersion: Int
        var flat: Bool
        var collapsed: Set<String>
        var filter: String
        var showsGenerated: Bool
    }

    var key: Key?
    var rows: [FileListRow] = []
}

extension WorktreeReview {
    /// Once every file is viewed and no thread awaits the reader, what the pull request says,
    /// where the approval is decided: "#12 Waiting for review · Checks: 1 failed" (SPEC §7.8).
    /// Nil before then, or without a pull request.
    var completionSummary: String? {
        guard let diff, !diff.files.isEmpty, viewed.viewedCount(in: diff) == diff.files.count,
            awaitingReply.isEmpty, let pullRequest
        else { return nil }
        var parts = ["#\(pullRequest.number) \(PullRequestBadge.state(pullRequest))"]
        if pullRequest.state == .open, let checks = PullRequestBadge.checks(pullRequest.checks) {
            parts.append(checks)
        }
        if let unpushed = unpushedCount, unpushed > 0 {
            parts.append(PullRequestBadge.unpushed(unpushed))
        }
        return parts.joined(separator: " · ")
    }

    var fileListRows: [FileListRow] {
        let key = FileListCache.Key(
            diffVersion: diffVersion, flat: flatFileList, collapsed: collapsedDirectories,
            filter: fileFilter, showsGenerated: showsGenerated)
        if fileListCache.key == key { return fileListCache.rows }
        let files = diff?.files ?? []
        let rows = FileTree.rows(
            files.map(\.diff.path), flat: flatFileList, collapsed: collapsedDirectories,
            filter: fileFilter, generated: Set(files.indices.filter { files[$0].isGenerated }),
            showsGenerated: showsGenerated)
        fileListCache.key = key
        fileListCache.rows = rows
        return rows
    }
}
