import Foundation

/// Which files the reader has marked viewed, per worktree (SPEC §11). A mark stores the new
/// side's content id when it was made, so a later change shows the file as changed since viewed,
/// and a rebase that keeps a file's content keeps its mark.
public struct ViewedMarks: Codable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case unviewed
        case viewed
        case changedSinceViewed
    }

    /// File path → content id at the time it was marked.
    public private(set) var marks: [String: String] = [:]

    public init(marks: [String: String] = [:]) {
        self.marks = marks
    }

    /// The new side's blob id, or the old side's for a deleted file. Nil when the file has no
    /// content id, which leaves it unviewable.
    public static func contentID(of file: ReviewFile) -> String? {
        if let new = nonZero(file.diff.newBlob), file.diff.newPath != nil { return new }
        if let old = nonZero(file.diff.oldBlob), file.diff.newPath == nil {
            return "deleted:" + old
        }
        return nil
    }

    /// The id to keep `text` under as what the reader saw, if it's the content the mark records:
    /// line-ending filters, say, make the text on disk differ from the blob.
    public func seen(_ file: ReviewFile, text: String) -> String? {
        guard let marked = marks[file.diff.path], marked == Self.contentID(of: file),
            marked == ReviewDiffBuilder.blobID(Data(text.utf8))
        else { return nil }
        return marked
    }

    public func status(of file: ReviewFile) -> Status {
        guard let marked = marks[file.diff.path] else { return .unviewed }
        return marked == Self.contentID(of: file) ? .viewed : .changedSinceViewed
    }

    /// Viewed files become unviewed; unviewed and changed files become viewed at their current
    /// content. Returns false when the file can't be marked.
    @discardableResult
    public mutating func toggle(_ file: ReviewFile) -> Bool {
        if status(of: file) == .viewed {
            marks[file.diff.path] = nil
            return true
        }
        guard let id = Self.contentID(of: file) else { return false }
        marks[file.diff.path] = id
        return true
    }

    /// Restores one file's mark exactly, for undo.
    public mutating func setMark(_ id: String?, for path: String) {
        marks[path] = id
    }

    public func viewedCount(in review: ReviewDiff) -> Int {
        review.files.count { status(of: $0) == .viewed }
    }

    private static func nonZero(_ id: String?) -> String? {
        guard let id, !id.isEmpty, !id.allSatisfy({ $0 == "0" }) else { return nil }
        return id
    }
}
