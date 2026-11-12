import Foundation

/// A bare repository of Seam's own that pull requests' heads and bases are fetched into, never
/// the reader's (SPEC §8.3.1, ADR 0008). Its objects are read through `GitClient` with the store
/// as the directory; this protocol only fetches, so the repo itself stays read-only.
public protocol PullRequestStore: Sendable {
    /// The store's git directory, to read with `GitClient`.
    var directory: URL { get }
    /// Fetches each PR's head as `refs/seam/pull/<number>` and each base as
    /// `refs/seam/base/<name>`, dropping the refs of PRs no longer asked for.
    func fetch(pullRequests: [Int], bases: [String], from repo: GitHubRepo)
        async throws(GitError)
    /// Deletes the store; the next fetch makes it again.
    func reset() async
}

/// Runs the user's git with their global and system config cleared, over https signed in with gh's
/// credentials: an `insteadOf` would turn the URL back into ssh, and the repo's own ssh setup
/// (`core.sshCommand` picking a key) is in a config the store doesn't read.
public struct CLIPullRequestStore: PullRequestStore {
    public let directory: URL
    /// The reader's repo's object directory, which the store borrows from.
    private let objects: URL
    private let remoteURL: @Sendable (GitHubRepo) -> String
    private let credentials: @Sendable () async -> URL?
    /// Past this many bytes of its own objects the store is repacked, dropping closed PRs'.
    private let repackAbove: Int
    private let environment: [String: String]
    private let logger = Logger(subsystem: "com.danielhedren.seam", category: "GitKit")
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "GitKit")

    /// `credentials` finds gh, whose `auth git-credential` signs the fetch in; without it the
    /// fetch runs unsigned, which public repos allow.
    public init(
        directory: URL, objects: URL,
        remoteURL: @escaping @Sendable (GitHubRepo) -> String = Self.httpsURL,
        credentials: @escaping @Sendable () async -> URL? = { nil },
        repackAbove: Int = 200 * 1024 * 1024,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directory = directory
        self.repackAbove = repackAbove
        self.objects = objects
        self.remoteURL = remoteURL
        self.credentials = credentials
        var environment = environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        for name in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY"] {
            environment[name] = nil
        }
        self.environment = environment
    }

    public static func httpsURL(_ repo: GitHubRepo) -> String {
        "https://\(repo.host)/\(repo.owner)/\(repo.name).git"
    }

    public func fetch(pullRequests: [Int], bases: [String], from repo: GitHubRepo)
        async throws(GitError)
    {
        let interval = signposter.beginInterval("pullRequestFetch")
        defer { signposter.endInterval("pullRequestFetch", interval) }
        try await prepare()
        try await dropRefs(keeping: Set(pullRequests))
        let refspecs =
            pullRequests.sorted().map { "+refs/pull/\($0)/head:refs/seam/pull/\($0)" }
            + Set(bases).sorted().map { "+refs/heads/\($0):refs/seam/base/\($0)" }
        guard !refspecs.isEmpty else { return }
        var options: [String] = []
        if let gh = await credentials() {
            // An empty helper first drops any the config names; the shell runs the `!` one.
            options = [
                "-c", "credential.helper=",
                "-c",
                "credential.helper=!'\(gh.path.replacing("'", with: "'\\''"))' auth git-credential",
            ]
        }
        try await git(
            options + [
                "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-auto-gc",
                remoteURL(repo),
            ] + refspecs)
        if size(of: directory.appending(path: "objects")) > repackAbove {
            try await git(["gc", "--quiet", "--prune=now"])
        }
    }

    /// What the store holds itself; the reader's objects, borrowed through alternates, aren't in it.
    private func size(of folder: URL) -> Int {
        let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let file = files?.nextObject() as? URL {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    public func reset() async {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A bare repository whose alternates name the reader's objects, so what the repo already has
    /// isn't fetched or stored twice.
    private func prepare() async throws(GitError) {
        let files = FileManager.default
        if !files.fileExists(atPath: directory.appending(path: "HEAD").path) {
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw .launchFailed("can't make \(directory.path): \(error)")
            }
            try await git(["init", "--quiet", "--bare", directory.path], in: directory)
        }
        let alternates = directory.appending(path: "objects/info/alternates")
        let line = objects.path + "\n"
        guard (try? String(contentsOf: alternates, encoding: .utf8)) != line else { return }
        do {
            try files.createDirectory(
                at: alternates.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(line.utf8).write(to: alternates, options: .atomic)
        } catch {
            throw .launchFailed("can't write \(alternates.path): \(error)")
        }
    }

    /// Closed PRs' refs go, so their objects can be dropped when the store is repacked.
    private func dropRefs(keeping numbers: Set<Int>) async throws(GitError) {
        let listed = try await git(["for-each-ref", "--format=%(refname)", "refs/seam/pull/"])
        let stale = String(decoding: listed, as: UTF8.self).split(separator: "\n")
            .filter { ref in Int(ref.split(separator: "/").last ?? "").map(numbers.contains) != true
            }
        guard !stale.isEmpty else { return }
        try await git(
            ["update-ref", "--stdin"],
            input: Data(stale.map { "delete \($0)\n" }.joined().utf8))
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL? = nil, input: Data? = nil)
        async throws(GitError) -> Data
    {
        let full =
            ["git"] + (directory == nil ? ["--git-dir=\(self.directory.path)"] : []) + arguments
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: full,
                directory: directory ?? self.directory, environment: environment, input: input)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .launchFailed(String(describing: error))
        }
        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            logger.info(
                "store git \(arguments.first ?? "", privacy: .public) exited \(result.status)")
            throw .nonZeroExit(arguments: arguments, status: result.status, stderr: stderr)
        }
        return result.stdout
    }
}
