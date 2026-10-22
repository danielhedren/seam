import CryptoKit
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
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { throw .unreadable(String(cString: strerror(errno))) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else {
            throw .unreadable(String(cString: strerror(errno)))
        }
        defer { flock(lock, LOCK_UN) }
        var threads = try read(url)
        let result = try change(&threads)
        try write(threads, to: url)
        return result
    }

    private struct Contents: Codable {
        var version: Int
        var threads: [ReviewThread]
    }

    private func read(_ url: URL) throws(ThreadError) -> [ReviewThread] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let contents: Contents
        do {
            contents = try decoder.decode(Contents.self, from: data)
        } catch {
            throw .unreadable("\(url.lastPathComponent): \(error)")
        }
        guard contents.version <= Self.formatVersion else {
            throw .unsupportedVersion(contents.version)
        }
        return contents.threads
    }

    private func write(_ threads: [ReviewThread], to url: URL) throws(ThreadError) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        do {
            let data = try encoder.encode(Contents(version: Self.formatVersion, threads: threads))
            try data.write(to: temporary)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        guard rename(temporary.path, url.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: temporary)
            throw .unreadable(message)
        }
    }
}
