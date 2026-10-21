import Foundation
import GitKit
import os

/// Both sides of a reviewed file in full, for context expansion and highlighting (SPEC §7.4, §8.4).
public struct FileContents: Equatable, Sendable {
    /// Nil when the side doesn't exist (added or deleted file) or isn't text.
    public var old: String?
    public var new: String?

    public init(old: String?, new: String?) {
        self.old = old
        self.new = new
    }
}

public struct FileContentLoader: Sendable {
    /// Files above this size aren't loaded; they keep plain, unexpandable rows.
    public static let maximumSize = 2_000_000

    private let git: any GitClient
    private let fileSystem: any FileSystem
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "SeamCore")

    public init(git: any GitClient, fileSystem: any FileSystem = LocalFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    /// Old sides come from their blobs. New sides come from the working tree, unless the scope
    /// stops at a commit, when they come from their blobs too.
    public func load(_ review: ReviewDiff, worktree: URL) async throws(GitError)
        -> [String: FileContents]
    {
        let interval = signposter.beginInterval("loadContents")
        defer { signposter.endInterval("loadContents", interval) }
        let text = review.files.filter { !$0.diff.isBinary && !$0.isDeferred }
        let readsWorkingTree = review.scope != .committed
        var blobs = Set<String>()
        for file in text {
            if let old = Self.blob(file.diff.oldBlob), file.diff.oldPath != nil {
                blobs.insert(old)
            }
            if !readsWorkingTree, let new = Self.blob(file.diff.newBlob), file.diff.newPath != nil {
                blobs.insert(new)
            }
        }
        let loaded = try await catBlobs(Array(blobs).sorted(), in: worktree)
        var result: [String: FileContents] = [:]
        for file in text {
            let old =
                file.diff.oldPath == nil ? nil : Self.blob(file.diff.oldBlob).flatMap { loaded[$0] }
            let new: String? =
                if file.diff.newPath == nil {
                    nil
                } else if readsWorkingTree {
                    workingTreeText(worktree.appending(path: file.diff.path))
                } else {
                    Self.blob(file.diff.newBlob).flatMap { loaded[$0] }
                }
            result[file.diff.path] = FileContents(old: old, new: new)
        }
        return result
    }

    /// A blob id from the patch, or nil for git's all-zero "no blob" id.
    static func blob(_ id: String?) -> String? {
        guard let id, !id.allSatisfy({ $0 == "0" }) else { return nil }
        return id
    }

    private func workingTreeText(_ url: URL) -> String? {
        guard fileSystem.symbolicLinkDestination(of: url) == nil,
            let size = try? fileSystem.size(of: url), size <= Self.maximumSize,
            let data = try? fileSystem.contents(of: url)
        else { return nil }
        return Self.text(data)
    }

    static func text(_ data: Data) -> String? {
        guard !data.prefix(8000).contains(0) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// One `git cat-file --batch` for every blob the review needs.
    func catBlobs(_ ids: [String], in worktree: URL) async throws(GitError) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let input = Data((ids.joined(separator: "\n") + "\n").utf8)
        let output = try await git.run(["cat-file", "--batch"], in: worktree, input: input)
        return try Self.parseBatch(output)
    }

    /// `<id> <type> <size>\n<content>\n` per object, or `<id> missing\n`.
    static func parseBatch(_ data: Data) throws(GitError) -> [String: String] {
        var result: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            guard let newline = data[index...].firstIndex(of: UInt8(ascii: "\n")) else {
                throw .unexpectedOutput("truncated cat-file header")
            }
            let header = String(decoding: data[index..<newline], as: UTF8.self)
                .split(separator: " ")
            index = data.index(after: newline)
            guard header.count == 3, let size = Int(header[2]) else { continue }
            let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            guard end - index == size else { throw .unexpectedOutput("truncated cat-file object") }
            if header[1] == "blob", size <= maximumSize, let text = text(data[index..<end]) {
                result[String(header[0])] = text
            }
            index = end < data.endIndex ? data.index(after: end) : end
        }
        return result
    }
}
