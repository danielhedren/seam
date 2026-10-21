import Foundation
import GitKit

public struct Repository: Equatable, Sendable {
    /// `git rev-parse --git-common-dir`, shared by every worktree; identifies the repo.
    public var commonDirectory: URL
    /// A worktree to run repo-wide commands from.
    public var anchor: URL
}

public struct Worktree: Equatable, Sendable, Identifiable {
    public var path: URL
    public var head: String?
    /// Short branch name; nil when detached.
    public var branch: String?
    public var isMain: Bool
    public var isDetached: Bool
    public var isLocked: Bool
    public var isPrunable: Bool
    public var isMissing: Bool

    public var id: String { path.path }
    public var name: String { path.lastPathComponent }
}

public struct RepositoryService: Sendable {
    private let git: any GitClient
    private let fileSystem: any FileSystem

    public init(git: any GitClient, fileSystem: any FileSystem = LocalFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    /// The repository containing `directory`, and the worktree `directory` belongs to.
    public func open(_ directory: URL) async throws(GitError) -> (Repository, URL) {
        let lines = try await git.string(
            ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"],
            in: directory
        ).split(separator: "\n")
        guard lines.count == 2 else {
            throw .unexpectedOutput("not inside a git worktree: \(directory.path)")
        }
        let common = URL(fileURLWithPath: String(lines[0]), isDirectory: true)
        let toplevel = URL(fileURLWithPath: String(lines[1]), isDirectory: true)
        return (Repository(commonDirectory: common, anchor: toplevel), toplevel)
    }

    public func worktrees(of repository: Repository) async throws(GitError) -> [Worktree] {
        let data = try await git.run(
            ["worktree", "list", "--porcelain", "-z"], in: repository.anchor)
        return WorktreeListParser.parse(data).enumerated().compactMap { index, entry in
            guard !entry.isBare else { return nil }
            let path = URL(fileURLWithPath: entry.path, isDirectory: true)
            return Worktree(
                path: path,
                head: entry.head,
                branch: entry.branch.map(RefName.shortBranch),
                isMain: index == 0,
                isDetached: entry.isDetached,
                isLocked: entry.lockReason != nil,
                isPrunable: entry.prunableReason != nil,
                isMissing: !fileSystem.directoryExists(path)
            )
        }
    }
}

enum RefName {
    static let heads = "refs/heads/"
    static let remotes = "refs/remotes/"

    static func shortBranch(_ ref: String) -> String {
        ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref
    }

    /// `refs/heads/x` → `x`, `refs/remotes/origin/x` → `origin/x`.
    static func short(_ ref: String) -> String {
        if ref.hasPrefix(heads) { return String(ref.dropFirst(heads.count)) }
        if ref.hasPrefix(remotes) { return String(ref.dropFirst(remotes.count)) }
        return ref
    }
}
