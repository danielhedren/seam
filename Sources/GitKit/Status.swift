import Foundation

public struct StatusEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case ordinary
        case renamedOrCopied
        case unmerged
        case untracked
        case ignored
    }

    public var kind: Kind
    /// Index (staged) status letter, `.` when unchanged; `?`/`!` for untracked and ignored.
    public var index: Character
    /// Working-tree status letter, `.` when unchanged.
    public var worktree: Character
    public var path: String
    /// The source path of a rename or copy.
    public var originalPath: String?

    public init(
        kind: Kind, index: Character, worktree: Character, path: String,
        originalPath: String? = nil
    ) {
        self.kind = kind
        self.index = index
        self.worktree = worktree
        self.path = path
        self.originalPath = originalPath
    }
}

public struct Status: Equatable, Sendable {
    /// `# branch.oid`; nil before the first commit.
    public var head: String?
    /// `# branch.head`; nil when detached.
    public var branch: String?
    public var entries: [StatusEntry] = []

    public init(head: String? = nil, branch: String? = nil, entries: [StatusEntry] = []) {
        self.head = head
        self.branch = branch
        self.entries = entries
    }
}

public enum StatusParser {
    /// Parses `git status --porcelain=v2 -z`, with or without `--branch`.
    public static func parse(_ data: Data) throws(GitError) -> Status {
        var status = Status()
        var fields = data.split(separator: 0)[...]
        while let field = fields.popFirst() {
            let line = String(decoding: field, as: UTF8.self)
            guard let type = line.first else { continue }
            switch type {
            case "#":
                header(line, into: &status)
            case "?", "!":
                let kind: StatusEntry.Kind = type == "?" ? .untracked : .ignored
                status.entries.append(
                    StatusEntry(
                        kind: kind, index: type, worktree: type, path: String(line.dropFirst(2))))
            case "1", "2", "u":
                // Fields before the path: 8 for ordinary, 9 for renames, 10 for unmerged.
                let count = type == "1" ? 8 : type == "2" ? 9 : 10
                let parts = line.split(
                    separator: " ", maxSplits: count, omittingEmptySubsequences: false)
                guard parts.count == count + 1, parts[1].count == 2 else {
                    throw .unexpectedOutput("status entry: \(line)")
                }
                var entry = StatusEntry(
                    kind: type == "1" ? .ordinary : type == "2" ? .renamedOrCopied : .unmerged,
                    index: parts[1].first ?? ".", worktree: parts[1].last ?? ".",
                    path: String(parts[count]))
                if type == "2" {
                    guard let original = fields.popFirst() else {
                        throw .unexpectedOutput("rename without a source path: \(line)")
                    }
                    entry.originalPath = String(decoding: original, as: UTF8.self)
                }
                status.entries.append(entry)
            default:
                throw .unexpectedOutput("status entry: \(line)")
            }
        }
        return status
    }

    private static func header(_ line: String, into status: inout Status) {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": status.head = value == "(initial)" ? nil : value
        case "branch.head": status.branch = value == "(detached)" ? nil : value
        default: break
        }
    }
}
