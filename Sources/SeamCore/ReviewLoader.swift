import Foundation
import GitKit

/// The git side of loading a review (SPEC §6, §8.2): the commits since the base, the range the
/// reader picked, the diff and the files' contents. The worktree model decides when to load and
/// what to keep; this only reads. The directory is a worktree today; a branch without one would
/// pass the repository's and a commit as the head.
public struct ReviewLoader: Sendable {
    public struct Diff: Sendable {
        /// The picked commits, nil when a rebase or reset removed them and the scope applies.
        public var selection: CommitSelection?
        public var diff: ReviewDiff
    }

    private let git: any GitClient
    private let fileSystem: any FileSystem

    public init(git: any GitClient, fileSystem: any FileSystem) {
        self.git = git
        self.fileSystem = fileSystem
    }

    /// The commits since the base, which the list shows before the diff is built.
    public func commits(from base: String, in directory: URL) async throws(GitError) -> CommitLog {
        try await CommitLog.load(base: base, in: directory, git: git)
    }

    public func diff(
        _ log: CommitLog, from base: String, in directory: URL, selection: CommitSelection?,
        scope: ReviewScope, options: DiffOptions
    ) async throws(GitError) -> Diff {
        let picked = selection.flatMap(log.range)
        let range = picked ?? (base, "HEAD", scope)
        let diff = try await ReviewDiffBuilder(git: git, fileSystem: fileSystem).build(
            worktree: directory, base: range.base, head: range.head, scope: range.scope,
            options: options)
        return Diff(selection: picked == nil ? nil : selection, diff: diff)
    }

    public func contents(of diff: ReviewDiff, in directory: URL) async throws(GitError)
        -> [String: FileContents]
    {
        try await FileContentLoader(git: git, fileSystem: fileSystem).load(
            diff, worktree: directory)
    }

    /// The directory's `.editorconfig`, read off the caller's actor.
    public func editorConfig(in directory: URL) async -> EditorConfig? {
        (try? fileSystem.contents(of: directory.appending(path: ".editorconfig")))
            .map { EditorConfig(String(decoding: $0, as: UTF8.self)) }
    }
}
