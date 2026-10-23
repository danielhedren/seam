import Foundation
import GitKit

/// Git with no user or system config and a fixed identity. Every call advances the clock one
/// minute, so commit SHAs and reflog order are deterministic (SPEC §10).
public struct HermeticGit: GitClient {
    private let home: URL
    private let ticks = Ticks()

    public init(home: URL) {
        self.home = home
    }

    public func run(_ arguments: [String], in directory: URL, input: Data?) async throws(GitError)
        -> Data
    {
        let date = "\(1_767_225_600 + 60 * ticks.next()) +0000"
        let environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.com",
            "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.com",
            "GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date,
        ]
        return try await CLIGitClient(environment: environment).run(
            arguments, in: directory, input: input)
    }
}

private final class Ticks: @unchecked Sendable {
    // Guarded by lock; tests call git from concurrent tasks.
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// A temporary directory removed when the test that created it ends.
public final class TemporaryDirectory: Sendable {
    public let url: URL

    public init() throws {
        // Also removed at exit, for a directory a test keeps alive to the end.
        url = Scratch.path("seam-tests")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// `/var/…` resolved to `/private/var/…`, as git prints it. `resolvingSymlinksInPath()`
    /// deliberately strips `/private`, so this uses realpath(3).
    public var resolved: URL {
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
