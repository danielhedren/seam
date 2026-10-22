import Foundation
import GitKit

public struct ReviewCommit: Equatable, Sendable, Identifiable {
    public var id: String
    public var shortID: String
    public var subject: String
    public var date: Date

    public init(id: String, shortID: String, subject: String, date: Date) {
        self.id = id
        self.shortID = shortID
        self.subject = subject
        self.date = date
    }
}

/// A contiguous run of the commit list, picked instead of a scope (SPEC §6.2).
public struct CommitSelection: Equatable, Sendable {
    public enum End: Hashable, Sendable {
        case workingTree
        case commit(String)
    }

    public var newest: End
    public var oldest: End

    public init(newest: End, oldest: End) {
        self.newest = newest
        self.oldest = oldest
    }
}

/// The commits a review covers, newest first (SPEC §7.2.1). First parents only, so a merge from
/// main is one entry rather than every commit it brought in.
public struct CommitLog: Equatable, Sendable {
    public static let limit = 500

    public var commits: [ReviewCommit]
    /// The commit the review diffs against.
    public var base: ReviewCommit
    /// More than `limit` commits; the oldest aren't listed.
    public var isTruncated: Bool

    public init(commits: [ReviewCommit], base: ReviewCommit, isTruncated: Bool = false) {
        self.commits = commits
        self.base = base
        self.isTruncated = isTruncated
    }

    public static func load(base: String, in worktree: URL, git: any GitClient)
        async throws(GitError) -> CommitLog
    {
        let format = ["--no-show-signature", "-z", "--format=%H%x1f%h%x1f%ct%x1f%s"]
        let listed = parse(
            try await git.string(
                ["log", "--first-parent", "-n", String(limit + 1)] + format + [
                    "\(base)..HEAD", "--",
                ], in: worktree))
        guard
            let baseCommit = parse(
                try await git.string(["log", "-n", "1"] + format + [base, "--"], in: worktree)
            ).first
        else { throw .unexpectedOutput("no commit \(base)") }
        return CommitLog(
            commits: Array(listed.prefix(limit)), base: baseCommit,
            isTruncated: listed.count > limit)
    }

    static func parse(_ output: String) -> [ReviewCommit] {
        output.split(separator: "\0").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines)
                .split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, let seconds = TimeInterval(fields[2]) else { return nil }
            return ReviewCommit(
                id: String(fields[0]), shortID: String(fields[1]), subject: String(fields[3]),
                date: Date(timeIntervalSince1970: seconds))
        }
    }

    /// The list's selectable rows, newest first.
    public var ends: [CommitSelection.End] {
        [.workingTree] + commits.map { .commit($0.id) }
    }

    /// The run from the newest to the oldest of `picked`, filling any gap. With the working-tree
    /// row hidden (nothing uncommitted), every commit means All, so later edits still show.
    public func selection(
        spanning picked: some Sequence<CommitSelection.End>, showsWorkingTree: Bool
    )
        -> CommitSelection?
    {
        let ends = ends
        let indices = picked.compactMap { ends.firstIndex(of: $0) }
        guard let newest = indices.min(), let oldest = indices.max() else { return nil }
        let run = CommitSelection(newest: ends[newest], oldest: ends[oldest])
        guard !showsWorkingTree, run == selection(for: .committed) else { return run }
        return selection(for: .all)
    }

    /// The selection a scope stands for; nil when it covers no rows.
    public func selection(for scope: ReviewScope) -> CommitSelection? {
        let newestCommit = commits.first.map { CommitSelection.End.commit($0.id) }
        let oldestCommit = commits.last.map { CommitSelection.End.commit($0.id) }
        return switch scope {
        case .all: CommitSelection(newest: .workingTree, oldest: oldestCommit ?? .workingTree)
        case .committed:
            newestCommit.flatMap { newest in
                oldestCommit.map { CommitSelection(newest: newest, oldest: $0) }
            }
        case .uncommitted: CommitSelection(newest: .workingTree, oldest: .workingTree)
        }
    }

    /// The scope a selection matches, so picking every row reads as "All" again.
    public func scope(matching selection: CommitSelection) -> ReviewScope? {
        guard !isTruncated else { return nil }
        return ReviewScope.allCases.first { self.selection(for: $0) == selection }
    }

    /// What to diff for a selection: the old side is the oldest commit's first parent. Nil when
    /// an end is no longer listed, as after a rebase.
    public func range(for selection: CommitSelection) -> (
        base: String, head: String, scope: ReviewScope
    )? {
        guard let newest = ends.firstIndex(of: selection.newest),
            let oldest = ends.firstIndex(of: selection.oldest), newest <= oldest
        else { return nil }
        guard case .commit(let oldestID) = selection.oldest else {
            return ("HEAD", "HEAD", .uncommitted)
        }
        return switch selection.newest {
        case .workingTree: (oldestID + "^", "HEAD", .all)
        case .commit(let newestID): (oldestID + "^", newestID, .committed)
        }
    }
}
