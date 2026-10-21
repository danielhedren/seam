import CryptoKit
import Foundation
import GitKit
import os

public enum ReviewScope: String, CaseIterable, Sendable {
    /// Base → working tree, plus untracked files.
    case all
    /// Base → HEAD.
    case committed
    /// HEAD → working tree, plus untracked files.
    case uncommitted
}

public enum WhitespaceMode: String, CaseIterable, Sendable {
    case show
    case ignoreAmount
    case ignoreAll
}

public struct DiffOptions: Equatable, Sendable {
    public static let defaultGeneratedGlobs = [
        "**/Generated/**", "**/*.g.cs", "**/package-lock.json", "**/*.lock",
    ].map(Glob.init)

    public var contextLines = 3
    public var whitespace = WhitespaceMode.show
    /// Paths treated as generated unless `.gitattributes` says otherwise (SPEC §6.3).
    public var generatedGlobs: [Glob]

    public init(
        contextLines: Int = 3, whitespace: WhitespaceMode = .show,
        generatedGlobs: [Glob] = DiffOptions.defaultGeneratedGlobs
    ) {
        self.contextLines = contextLines
        self.whitespace = whitespace
        self.generatedGlobs = generatedGlobs
    }

    /// Every option whose user config would otherwise change the output (SPEC §8.3).
    var arguments: [String] {
        var arguments = [
            "diff", "--no-ext-diff", "--no-color", "--no-textconv", "--histogram", "-M", "-C",
            "--src-prefix=a/", "--dst-prefix=b/", "--no-relative", "--full-index",
            "-U\(contextLines)",
        ]
        switch whitespace {
        case .show: break
        case .ignoreAmount: arguments.append("-b")
        case .ignoreAll: arguments.append("-w")
        }
        return arguments
    }
}

public struct ReviewFile: Equatable, Sendable {
    public var diff: FileDiff
    public var isUntracked = false
    /// Too large to load up front (SPEC §6.3); `diff` has no hunks.
    public var isDeferred = false
    /// `linguist-generated`, or matched by a generated-file glob; listed last and collapsed.
    public var isGenerated = false

    public init(
        diff: FileDiff, isUntracked: Bool = false, isDeferred: Bool = false,
        isGenerated: Bool = false
    ) {
        self.diff = diff
        self.isUntracked = isUntracked
        self.isDeferred = isDeferred
        self.isGenerated = isGenerated
    }

    /// Diffs this long start collapsed (SPEC §6.3).
    public static let largeLineCount = 20_000

    public var isLarge: Bool {
        diff.hunks.reduce(0) { $0 + $1.lines.count } > Self.largeLineCount
    }

    /// Generated and large files start collapsed; the reader opens them on demand.
    public var startsCollapsed: Bool { isGenerated || isLarge || isDeferred }
}

public struct ReviewDiff: Equatable, Sendable {
    public var scope: ReviewScope
    public var files: [ReviewFile]

    public var additions: Int { files.reduce(0) { $0 + $1.diff.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.diff.deletions } }

    public init(scope: ReviewScope, files: [ReviewFile]) {
        self.scope = scope
        self.files = files
    }
}

public struct ReviewDiffBuilder: Sendable {
    /// Untracked files above this size are listed but not read.
    public static let deferredSize = 1_000_000

    private let git: any GitClient
    private let fileSystem: any FileSystem
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "SeamCore")

    public init(git: any GitClient, fileSystem: any FileSystem = LocalFileSystem()) {
        self.git = git
        self.fileSystem = fileSystem
    }

    public func build(
        worktree: URL, base: String, head: String = "HEAD", scope: ReviewScope,
        options: DiffOptions = DiffOptions()
    ) async throws(GitError) -> ReviewDiff {
        let interval = signposter.beginInterval("reviewDiff")
        defer { signposter.endInterval("reviewDiff", interval) }

        let range: [String] =
            switch scope {
            case .all: [base]
            case .committed: [base, head]
            case .uncommitted: [head]
            }
        let patch = try await git.run(options.arguments + range + ["--"], in: worktree)
        var files = try PatchParser.parse(patch).map { ReviewFile(diff: $0) }
        if scope != .committed {
            files += try await untrackedFiles(worktree)
        }
        let generated = try await generatedPaths(
            files.map(\.diff.path), globs: options.generatedGlobs, in: worktree)
        for index in files.indices where generated.contains(files[index].diff.path) {
            files[index].isGenerated = true
        }
        files.sort { lhs, rhs in
            lhs.isGenerated != rhs.isGenerated
                ? !lhs.isGenerated
                : lhs.diff.path.utf8.lexicographicallyPrecedes(rhs.diff.path.utf8)
        }
        return ReviewDiff(scope: scope, files: files)
    }

    /// `.gitattributes` decides first: `linguist-generated` set marks a file, unset clears it
    /// even when a glob matches. Unspecified paths fall back to the globs.
    func generatedPaths(_ paths: [String], globs: [Glob], in worktree: URL) async throws(GitError)
        -> Set<String>
    {
        guard !paths.isEmpty else { return [] }
        let input = Data(paths.joined(separator: "\0").utf8) + Data([0])
        let output = try await git.run(
            ["check-attr", "-z", "--stdin", "linguist-generated"], in: worktree, input: input)
        let fields = output.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var attributes: [String: String] = [:]
        var index = 0
        while index + 2 < fields.count {
            attributes[fields[index]] = fields[index + 2]
            index += 3
        }
        return Set(
            paths.filter { path in
                switch attributes[path] {
                case "set", "true": true
                case "unset", "false": false
                default: globs.contains { $0.matches(path) }
                }
            })
    }

    private func untrackedFiles(_ worktree: URL) async throws(GitError) -> [ReviewFile] {
        let output = try await git.run(
            ["ls-files", "--others", "--exclude-standard", "-z"], in: worktree)
        return output.split(separator: 0).map { field in
            let path = String(decoding: field, as: UTF8.self)
            return untracked(path, at: worktree.appending(path: path))
        }
    }

    /// The id git would give `data` as a blob. Computed here from bytes already read, so a file
    /// that vanishes or a nested repository (listed as `dir/`) can't fail the load; deferred
    /// files have no id and can't be marked viewed.
    static func blobID(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func untracked(_ path: String, at url: URL) -> ReviewFile {
        var diff = FileDiff(oldPath: nil, newPath: path, status: .added)
        if let destination = fileSystem.symbolicLinkDestination(of: url) {
            diff.newMode = "120000"
            diff.hunks = Self.additionHunk(Data(destination.utf8), endsWithNewline: false)
            diff.newBlob = Self.blobID(Data(destination.utf8))
            return ReviewFile(diff: diff, isUntracked: true)
        }
        diff.newMode = fileSystem.isExecutable(url) ? "100755" : "100644"
        guard let size = try? fileSystem.size(of: url), size <= Self.deferredSize else {
            return ReviewFile(diff: diff, isUntracked: true, isDeferred: true)
        }
        guard let data = try? fileSystem.contents(of: url) else {
            return ReviewFile(diff: diff, isUntracked: true, isDeferred: true)
        }
        diff.newBlob = Self.blobID(data)
        // Git's own heuristic: a NUL in the first 8000 bytes means binary.
        if data.prefix(8000).contains(0) {
            diff.isBinary = true
        } else {
            diff.hunks = Self.additionHunk(data, endsWithNewline: data.last == UInt8(ascii: "\n"))
        }
        return ReviewFile(diff: diff, isUntracked: true)
    }

    static func additionHunk(_ data: Data, endsWithNewline: Bool) -> [Hunk] {
        guard !data.isEmpty else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if endsWithNewline { lines.removeLast() }
        var hunk = Hunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, section: "")
        hunk.lines = lines.enumerated().map { offset, bytes in
            DiffLine(
                kind: .added, text: String(decoding: bytes, as: UTF8.self), oldNumber: nil,
                newNumber: offset + 1)
        }
        if !endsWithNewline { hunk.lines[hunk.lines.count - 1].noNewlineAtEnd = true }
        return [hunk]
    }
}
