import Foundation
import GitKit

/// The cheap per-row numbers of the worktree list (SPEC §7.2), refreshed for hidden worktrees.
public struct WorktreeActivity: Equatable, Sendable {
    /// Paths with staged, unstaged or untracked changes.
    public var uncommittedFiles: Int
    /// The newest of the HEAD commit and the changed files' modification times.
    public var lastChange: Date?

    public init(uncommittedFiles: Int, lastChange: Date?) {
        self.uncommittedFiles = uncommittedFiles
        self.lastChange = lastChange
    }
}

public struct WorktreeActivityService: Sendable {
    private let git: any GitClient
    private let fileSystem: any FileSystem

    public init(git: any GitClient, fileSystem: any FileSystem = LocalFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    public func activity(of worktree: URL) async throws(GitError) -> WorktreeActivity {
        let status = try StatusParser.parse(
            try await git.run(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"],
                in: worktree))
        let committed = try await git.optionalLine(
            ["log", "-1", "--no-show-signature", "--format=%ct"], in: worktree
        )
        .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let changed = status.entries.compactMap {
            fileSystem.modificationDate(of: worktree.appending(path: $0.path))
        }
        return WorktreeActivity(
            uncommittedFiles: status.entries.count,
            lastChange: (changed + [committed].compactMap(\.self)).max())
    }
}
