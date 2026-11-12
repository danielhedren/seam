import Foundation

public enum GitError: Error, Equatable, Sendable {
    case launchFailed(String)
    case nonZeroExit(arguments: [String], status: Int32, stderr: String)
    case cancelled
    case unexpectedOutput(String)
}

public protocol GitClient: Sendable {
    /// Runs `git <arguments>` in `directory` and returns its standard output.
    func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError) -> Data
}

extension GitClient {
    public func run(_ arguments: [String], in directory: URL) async throws(GitError) -> Data {
        try await run(arguments, in: directory, input: nil)
    }

    public func string(_ arguments: [String], in directory: URL, input: Data? = nil)
        async throws(GitError) -> String
    {
        String(decoding: try await run(arguments, in: directory, input: input), as: UTF8.self)
    }

    /// Output without the trailing newline, or nil when git exits non-zero.
    public func optionalLine(_ arguments: [String], in directory: URL) async throws(GitError)
        -> String?
    {
        do {
            let output = try await string(arguments, in: directory)
            return output.hasSuffix("\n") ? String(output.dropLast()) : output
        } catch {
            if case .nonZeroExit = error { return nil }
            throw error
        }
    }
}

/// Runs the user's own `git` so their config, attributes and worktrees behave as in the terminal.
public struct CLIGitClient: GitClient {
    /// Options prepended to every invocation (SPEC §8.3).
    static let globalOptions = ["-c", "core.quotepath=off", "-c", "color.ui=never", "--no-pager"]

    private let executable: URL
    private let environment: [String: String]
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "GitKit")

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/env"),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executable = executable
        var environment = environment
        // Reads must never take the index lock while agents are writing in the same worktree.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        self.environment = environment
    }

    public func run(
        _ arguments: [String], in directory: URL, input: Data?
    ) async throws(GitError) -> Data {
        let fullArguments = ["git"] + Self.globalOptions + arguments
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: executable,
                arguments: fullArguments,
                directory: directory,
                environment: environment,
                input: input
            )
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .launchFailed(String(describing: error))
        }
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            logger.debug("git \(arguments, privacy: .public) exited \(result.status)")
            throw .nonZeroExit(arguments: arguments, status: result.status, stderr: stderr)
        }
        return result.stdout
    }
}

/// Runs every command on one git directory. A bare repository needs it named: with
/// `safe.bareRepository=explicit` git won't use one found from its folder alone. Commands run
/// outside it, so one that's gone gets git's "not a git repository", not a failed launch.
public struct GitDirectoryClient: GitClient {
    private let inner: any GitClient
    public let directory: URL

    public init(_ inner: any GitClient, directory: URL) {
        self.inner = inner
        self.directory = directory
    }

    public func run(_ arguments: [String], in _: URL, input: Data?) async throws(GitError)
        -> Data
    {
        try await inner.run(
            ["--git-dir=\(directory.path)"] + arguments,
            in: FileManager.default.temporaryDirectory, input: input)
    }
}
