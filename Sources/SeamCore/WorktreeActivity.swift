import Foundation
import GitKit

/// Files and lines changed since a base, the working tree and untracked files included.
public struct DiffStat: Equatable, Sendable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    /// `git diff --shortstat`'s one line, such as "2 files changed, 5 insertions(+)".
    static func parse(_ line: String) -> DiffStat {
        var stat = DiffStat(files: 0, additions: 0, deletions: 0)
        for part in line.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let count = words.first.flatMap({ Int($0) }), words.count > 1 else { continue }
            if words[1].hasPrefix("file") {
                stat.files = count
            } else if words[1].hasPrefix("insertion") {
                stat.additions = count
            } else if words[1].hasPrefix("deletion") {
                stat.deletions = count
            }
        }
        return stat
    }
}

/// The cheap per-row numbers of the worktree list (SPEC §7.2), refreshed for hidden worktrees.
public struct WorktreeActivity: Equatable, Sendable {
    /// Paths with staged, unstaged or untracked changes.
    public var uncommittedFiles: Int
    /// The newest of the HEAD commit and the changed files' modification times.
    public var lastChange: Date?
    /// Against the review's base; nil until the base is known.
    public var changes: DiffStat?

    public init(uncommittedFiles: Int, lastChange: Date?, changes: DiffStat? = nil) {
        self.uncommittedFiles = uncommittedFiles
        self.lastChange = lastChange
        self.changes = changes
    }
}

public struct WorktreeActivityService: Sendable {
    private let git: any GitClient
    private let fileSystem: any FileSystem

    public init(git: any GitClient, fileSystem: any FileSystem = LocalFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    public func activity(of worktree: URL, base: String? = nil) async throws(GitError)
        -> WorktreeActivity
    {
        // Independent git calls, run side by side: every row of the list makes them.
        let git = git
        async let statusOutput = Result { () async throws(GitError) -> Data in
            try await git.run(
                ["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"],
                in: worktree)
        }
        async let headTime = Result { () async throws(GitError) -> String? in
            try await git.optionalLine(
                ["log", "-1", "--no-show-signature", "--format=%ct"], in: worktree)
        }
        async let shortstat = Result { () async throws(GitError) -> DiffStat? in
            guard let base else { return nil }
            return DiffStat.parse(
                try await git.string(
                    ["diff", "--shortstat", "--no-ext-diff", "--no-textconv", "-M", base, "--"],
                    in: worktree))
        }
        let status = try StatusParser.parse(try await statusOutput.get())
        let committed = try await headTime.get()
            .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        var changes = try await shortstat.get()
        let changed = status.entries.compactMap {
            fileSystem.modificationDate(of: worktree.appending(path: $0.path))
        }
        if changes != nil {
            // Git leaves untracked files out; an untracked nested repo is listed as "dir/".
            for entry in status.entries where entry.kind == .untracked && !entry.path.hasSuffix("/")
            {
                changes?.files += 1
                changes?.additions += lineCount(worktree.appending(path: entry.path))
            }
        }
        return WorktreeActivity(
            uncommittedFiles: status.entries.count,
            lastChange: (changed + [committed].compactMap(\.self)).max(), changes: changes)
    }

    /// Text files only, and not ones too large for the diff to read either (SPEC §6.3).
    private func lineCount(_ url: URL) -> Int {
        guard let size = try? fileSystem.size(of: url), size <= ReviewDiffBuilder.deferredSize,
            let data = try? fileSystem.contents(of: url), !ReviewDiffBuilder.isBinary(data)
        else { return 0 }
        let newlines = data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
        return newlines + (data.last.map { $0 == UInt8(ascii: "\n") ? 0 : 1 } ?? 0)
    }
}
