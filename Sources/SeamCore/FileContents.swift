import Foundation
import GitKit
import os

/// Both sides of a reviewed file in full, for context expansion, highlighting and binary entries
/// (SPEC §6.3, §7.4, §8.4). A nil side doesn't exist, wasn't loaded, or isn't that kind of file.
public struct FileContents: Equatable, Sendable {
    public var old: String?
    public var new: String?
    /// Binary files: each side's size in bytes.
    public var oldSize: Int?
    public var newSize: Int?
    /// Images: each side's encoded bytes, for the preview.
    public var oldImage: Data?
    public var newImage: Data?

    public init(
        old: String? = nil, new: String? = nil, oldSize: Int? = nil, newSize: Int? = nil,
        oldImage: Data? = nil, newImage: Data? = nil
    ) {
        self.old = old
        self.new = new
        self.oldSize = oldSize
        self.newSize = newSize
        self.oldImage = oldImage
        self.newImage = newImage
    }
}

public struct FileContentLoader: Sendable {
    /// Text and images above this size aren't loaded; their rows stay plain.
    public static let maximumSize = 2_000_000
    public static let maximumImageSize = 10_000_000
    /// Formats NSImage decodes, previewed side by side (SPEC §6.3).
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "pdf", "webp", "heic", "tiff", "bmp", "ico",
    ]

    private let git: any GitClient
    private let fileSystem: any FileSystem
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "SeamCore")

    public init(git: any GitClient, fileSystem: any FileSystem = LocalFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    public static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    private enum Kind { case text, image, sizeOnly }

    private enum Source {
        case blob(String)
        case disk(URL)
    }

    /// Old sides come from their blobs. New sides come from the working tree, unless the scope
    /// stops at a commit, when they come from their blobs too. Blob reads take one
    /// `cat-file --batch` for content and one `--batch-check` for sizes.
    public func load(_ review: ReviewDiff, worktree: URL) async throws(GitError)
        -> [String: FileContents]
    {
        let interval = signposter.beginInterval("loadContents")
        defer { signposter.endInterval("loadContents", interval) }
        let readsWorkingTree = review.scope != .committed
        var plan: [(ReviewFile, Kind, old: Source?, new: Source?)] = []
        var contentBlobs = Set<String>()
        var sizeBlobs = Set<String>()
        for file in review.files where !file.isDeferred {
            let kind: Kind =
                !file.diff.isBinary ? .text : Self.isImage(file.diff.path) ? .image : .sizeOnly
            let old = file.diff.oldPath == nil ? nil : Self.blob(file.diff.oldBlob).map(Source.blob)
            let new: Source? =
                if file.diff.newPath == nil {
                    nil
                } else if readsWorkingTree {
                    .disk(worktree.appending(path: file.diff.path))
                } else {
                    Self.blob(file.diff.newBlob).map(Source.blob)
                }
            for case .blob(let id) in [old, new].compactMap(\.self) {
                if kind == .sizeOnly { sizeBlobs.insert(id) } else { contentBlobs.insert(id) }
            }
            plan.append((file, kind, old, new))
        }
        let blobs = try await catBlobs(contentBlobs.sorted(), in: worktree)
        let sizes = try await blobSizes(sizeBlobs.union(contentBlobs).sorted(), in: worktree)

        var result: [String: FileContents] = [:]
        for (file, kind, old, new) in plan {
            func data(_ source: Source?, limit: Int) -> Data? {
                switch source {
                case .blob(let id): blobs[id].flatMap { $0.count <= limit ? $0 : nil }
                case .disk(let url): diskData(url, limit: limit)
                case nil: nil
                }
            }
            func size(_ source: Source?) -> Int? {
                switch source {
                case .blob(let id): sizes[id]
                case .disk(let url): try? fileSystem.size(of: url)
                case nil: nil
                }
            }
            var contents = FileContents()
            switch kind {
            case .text:
                contents.old = data(old, limit: Self.maximumSize).flatMap(Self.text)
                contents.new = data(new, limit: Self.maximumSize).flatMap(Self.text)
            case .image:
                contents.oldImage = data(old, limit: Self.maximumImageSize)
                contents.newImage = data(new, limit: Self.maximumImageSize)
                contents.oldSize = size(old)
                contents.newSize = size(new)
            case .sizeOnly:
                contents.oldSize = size(old)
                contents.newSize = size(new)
            }
            result[file.diff.path] = contents
        }
        return result
    }

    /// A blob id from the patch, or nil for git's all-zero "no blob" id.
    static func blob(_ id: String?) -> String? {
        guard let id, !id.allSatisfy({ $0 == "0" }) else { return nil }
        return id
    }

    private func diskData(_ url: URL, limit: Int) -> Data? {
        guard fileSystem.symbolicLinkDestination(of: url) == nil,
            let size = try? fileSystem.size(of: url), size <= limit
        else { return nil }
        return try? fileSystem.contents(of: url)
    }

    static func text(_ data: Data) -> String? {
        guard !ReviewDiffBuilder.isBinary(data) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func catBlobs(_ ids: [String], in worktree: URL) async throws(GitError) -> [String: Data] {
        guard !ids.isEmpty else { return [:] }
        let input = Data((ids.joined(separator: "\n") + "\n").utf8)
        return try Self.parseBatch(
            try await git.run(["cat-file", "--batch"], in: worktree, input: input))
    }

    func blobSizes(_ ids: [String], in worktree: URL) async throws(GitError) -> [String: Int] {
        guard !ids.isEmpty else { return [:] }
        let input = Data((ids.joined(separator: "\n") + "\n").utf8)
        let output = String(
            decoding: try await git.run(["cat-file", "--batch-check"], in: worktree, input: input),
            as: UTF8.self)
        var sizes: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 3, let size = Int(fields[2]) { sizes[String(fields[0])] = size }
        }
        return sizes
    }

    /// `<id> <type> <size>\n<content>\n` per object, or `<id> missing\n`.
    static func parseBatch(_ data: Data) throws(GitError) -> [String: Data] {
        var result: [String: Data] = [:]
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
            if header[1] == "blob" { result[String(header[0])] = Data(data[index..<end]) }
            index = end < data.endIndex ? data.index(after: end) : end
        }
        return result
    }
}
