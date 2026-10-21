import Foundation
import GitKit

/// A throwaway repository with a local bare `origin`, built from real git commands.
public struct FixtureRepo: Sendable {
    public let directory: TemporaryDirectory
    public let git: HermeticGit
    /// The main worktree.
    public let main: URL
    public let origin: URL

    public init() async throws {
        directory = try TemporaryDirectory()
        let root = directory.resolved
        git = HermeticGit(home: root)
        main = root.appending(path: "repo", directoryHint: .isDirectory)
        origin = root.appending(path: "origin.git", directoryHint: .isDirectory)
        _ = try await git.run(["init", "-q", "--bare", "-b", "main", origin.path], in: root)
        _ = try await git.run(["init", "-q", "-b", "main", main.path], in: root)
        try await run("remote", "add", "origin", origin.path)
        try await commit("README.md", "fixture\n", "initial")
        try await run("push", "-q", "-u", "origin", "main")
        try await run("remote", "set-head", "origin", "main")
    }

    @discardableResult
    public func run(_ arguments: String..., in worktree: URL? = nil) async throws -> String {
        try await git.string(arguments, in: worktree ?? main).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// Writes `file` and commits it; returns the new commit's SHA.
    @discardableResult
    public func commit(
        _ file: String, _ content: String, _ message: String, in worktree: URL? = nil
    )
        async throws
        -> String
    {
        let directory = worktree ?? main
        try write(file, content, in: directory)
        try await run("add", "--", file, in: directory)
        try await run("commit", "-q", "-m", message, in: directory)
        return try await run("rev-parse", "HEAD", in: directory)
    }

    public func write(_ file: String, _ content: String, in worktree: URL? = nil) throws {
        let url = (worktree ?? main).appending(path: file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    /// Adds a worktree on a new branch cut from `start`.
    public func worktree(_ name: String, branch: String, from start: String) async throws -> URL {
        let path = directory.resolved.appending(path: "wt-\(name)", directoryHint: .isDirectory)
        try await run("worktree", "add", "-q", "--no-track", "-b", branch, path.path, start)
        return path
    }

    public func sha(_ revision: String) async throws -> String {
        try await run("rev-parse", revision)
    }
}
