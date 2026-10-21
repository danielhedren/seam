public enum FileStatus: Equatable, Sendable {
    case added
    case deleted
    case modified
    case renamed(similarity: Int)
    case copied(similarity: Int)

    public var letter: Character {
        switch self {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .copied: "C"
        }
    }
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }

    public var kind: Kind
    /// Line content without the prefix or the line terminator. A CR before LF is kept.
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// The `\ No newline at end of file` marker followed this line.
    public var noNewlineAtEnd = false

    public init(kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct Hunk: Equatable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The function context git prints after the second `@@`.
    public var section: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, section: String) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.section = section
        self.lines = []
    }
}

public struct FileDiff: Equatable, Sendable {
    /// Nil for an added file.
    public var oldPath: String?
    /// Nil for a deleted file.
    public var newPath: String?
    public var status: FileStatus
    public var oldMode: String?
    public var newMode: String?
    public var oldBlob: String?
    public var newBlob: String?
    public var isBinary = false
    public var hunks: [Hunk] = []

    public init(oldPath: String?, newPath: String?, status: FileStatus) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
    }

    public var path: String { newPath ?? oldPath ?? "" }

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } }
    }
}
