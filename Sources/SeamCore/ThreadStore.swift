import Crypto
import Foundation

/// Review threads on disk (SPEC §7.7), shared by the app and the `seam` command: one JSON file
/// per repo, outside the repository. Changes happen under an exclusive `flock` and land by
/// rename, so a reader sees the old file or the new one and two writers can't lose each other's
/// change.
public struct ThreadStore: Sendable {
    public static let formatVersion = 1

    public let directory: URL

    public init(
        directory: URL = URL.applicationSupportDirectory.appending(
            path: "Seam/threads", directoryHint: .isDirectory)
    ) {
        self.directory = directory
    }

    /// Named after the repo for a person looking in the folder, and a hash of its git directory
    /// so two repos with one name don't share a file.
    public func file(for repository: Repository) -> URL {
        let path = repository.commonDirectory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
        let name = repository.commonDirectory.deletingLastPathComponent().lastPathComponent
        return directory.appending(path: "\(name)-\(digest).json")
    }

    public func threads(for repository: Repository) throws(ThreadError) -> [ReviewThread] {
        try read(file(for: repository))
    }

    /// Reads, changes and writes the repo's threads as one step against other writers.
    @discardableResult
    public func update<Result>(
        _ repository: Repository, _ change: (inout [ReviewThread]) throws(ThreadError) -> Result
    ) throws(ThreadError) -> Result {
        let url = file(for: repository)
        return try locked(url) { () throws(ThreadError) in
            var threads = try read(url)
            let result = try change(&threads)
            try write(threads, to: url)
            return result
        }
    }

    private func locked<Result>(_ url: URL, _ body: () throws(ThreadError) -> Result)
        throws(ThreadError) -> Result
    {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { throw .unwritable(String(cString: strerror(errno))) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else {
            throw .unwritable(String(cString: strerror(errno)))
        }
        defer { flock(lock, LOCK_UN) }
        return try body()
    }

    /// The pull request threads the app read last (SPEC §7.9), beside the repo's own file so
    /// `seam` lists them without the app; only the app writes it.
    public func gitHubFile(for repository: Repository) -> URL {
        let url = file(for: repository)
        return url.deletingPathExtension().appendingPathExtension("github.json")
    }

    public func gitHubThreads(for repository: Repository) throws(ThreadError) -> GitHubThreadFile {
        let contents = try contents(of: gitHubFile(for: repository))
        return GitHubThreadFile(threads: contents?.threads ?? [], read: contents?.read ?? [:])
    }

    /// Replaces one worktree's pull request threads with a newer read, and returns them as
    /// stored.
    @discardableResult
    public func saveGitHubThreads(
        _ threads: [ReviewThread], worktree: String, read: Date, for repository: Repository
    ) throws(ThreadError) -> [ReviewThread] {
        let url = gitHubFile(for: repository)
        return try locked(url) { () throws(ThreadError) in
            let contents = try contents(of: url)
            let all = contents?.threads ?? []
            let others = all.filter { $0.worktree != worktree }
            let stamped = GitHubThreads.stamped(
                threads, previous: all.filter { $0.worktree == worktree }, now: read)
            var times = contents?.read ?? [:]
            times[worktree] = read
            try write(others + stamped, read: times, to: url)
            return stamped
        }
    }

    /// Drops the pull request threads and read times of worktrees not in `worktrees`; writes only
    /// when something goes. Returns the threads left.
    @discardableResult
    public func pruneGitHubThreads(keeping worktrees: Set<String>, for repository: Repository)
        throws(ThreadError) -> [ReviewThread]
    {
        let url = gitHubFile(for: repository)
        return try locked(url) { () throws(ThreadError) in
            guard let contents = try contents(of: url) else { return [] }
            let kept = contents.threads.filter { worktrees.contains($0.worktree) }
            let read = (contents.read ?? [:]).filter { worktrees.contains($0.key) }
            if kept.count != contents.threads.count || read.count != (contents.read ?? [:]).count {
                try write(kept, read: read, to: url)
            }
            return kept
        }
    }

    private struct Contents: Codable {
        var version: Int
        var threads: [ReviewThread]
        /// When each worktree's pull request threads were read, in the GitHub file.
        var read: [String: Date]?
    }

    private func read(_ url: URL) throws(ThreadError) -> [ReviewThread] {
        try contents(of: url)?.threads ?? []
    }

    private func contents(of url: URL) throws(ThreadError) -> Contents? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ThreadTime.decoding
        let contents: Contents
        do {
            contents = try decoder.decode(Contents.self, from: data)
        } catch {
            throw .unreadable("\(url.lastPathComponent): \(error)")
        }
        guard contents.version <= Self.formatVersion else {
            throw .unsupportedVersion(contents.version)
        }
        return contents
    }

    private func write(
        _ threads: [ReviewThread], read: [String: Date]? = nil, to url: URL
    ) throws(ThreadError) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ThreadTime.encoding
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            let data = try encoder.encode(
                Contents(version: Self.formatVersion, threads: threads, read: read))
            try data.write(to: temporary)
        } catch {
            throw .unwritable(error.localizedDescription)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw .unwritable(message)
        }
    }
}

/// The GitHub file's contents: the threads, and when each worktree's were read.
public struct GitHubThreadFile: Equatable, Sendable {
    public var threads: [ReviewThread]
    public var read: [String: Date]
}

/// Thread times in ISO 8601 with milliseconds, because `seam wait --since` compares against
/// them (SPEC §13); whole-second times from older files still read.
public enum ThreadTime {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func string(_ date: Date) -> String {
        date.formatted(withFraction)
    }

    public static func date(_ text: String) -> Date? {
        (try? withFraction.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    public static var encoding: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(date))
        }
    }

    public static var decoding: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "not an ISO 8601 time: \(text)")
            }
            return date
        }
    }
}
