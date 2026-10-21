import Foundation

public struct WorktreeEntry: Equatable, Sendable {
    public var path: String
    /// Nil for a bare repository entry.
    public var head: String?
    /// Full ref name, e.g. `refs/heads/main`; nil when detached or bare.
    public var branch: String?
    public var isBare = false
    public var isDetached = false
    /// Present when locked; empty when locked without a reason.
    public var lockReason: String?
    public var prunableReason: String?

    public init(path: String) { self.path = path }
}

public enum WorktreeListParser {
    /// Parses `git worktree list --porcelain -z`: NUL-terminated attribute lines, with an empty
    /// field ending each worktree.
    public static func parse(_ data: Data) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            let line = String(decoding: field, as: UTF8.self)
            if line.isEmpty {
                if let entry = current { entries.append(entry) }
                current = nil
                continue
            }
            let (key, value) = split(line)
            if key == "worktree" {
                if let entry = current { entries.append(entry) }
                current = WorktreeEntry(path: value ?? "")
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch": current?.branch = value
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.lockReason = value ?? ""
            case "prunable": current?.prunableReason = value ?? ""
            default: break
            }
        }
        if let entry = current { entries.append(entry) }
        return entries
    }

    private static func split(_ line: String) -> (String, String?) {
        guard let space = line.firstIndex(of: " ") else { return (line, nil) }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }
}
