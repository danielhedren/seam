import DiffView
import Foundation
import SeamCore

/// Where a thread is in the diff as it is now (SPEC §7.7).
enum ThreadPlacement: Equatable {
    case lines(ClosedRange<Int>)
    /// Its lines are gone from the file.
    case outdated
    /// Written on a commit after the newest one shown, so its lines may not exist yet.
    case later
    /// Its file isn't in this diff, or its text isn't loaded.
    case notShown
}

struct FileThreadCounts: Equatable {
    var open = 0
    var resolved = 0
    /// A pull request's threads, which get a dot of their own (SPEC §7.9).
    var gitHubOpen = 0
    var gitHubResolved = 0
}

struct PlacedThread: Equatable, Identifiable {
    var thread: ReviewThread
    var placement: ThreadPlacement

    var id: String { thread.id }

    /// The diff has a row for it, so it opens there rather than in the panel.
    var isInDiff: Bool { if case .lines = placement { true } else { false } }
}

/// Placements and markers per (threads, diff, contents) version: placing splits each file's text,
/// a marker parses its comment's Markdown, and the diff view asks for both on every update.
final class ThreadPlacementCache {
    var key: [Int] = []
    var placed: [PlacedThread] = []
    var markersKey: [Int] = []
    var markers: [String: [ThreadMarker]] = [:]
}

extension WorktreeReview {
    /// This worktree's threads with where they are now, open ones first, then by file and line.
    var placedThreads: [PlacedThread] {
        guard let threads else { return [] }
        let key = [
            threads.version, diffVersion, contentsVersion,
            services.settings.showsPullRequests ? 1 : 0,
        ]
        if placementCache.key == key { return placementCache.placed }
        let paths = Set(diff?.files.map(\.diff.path) ?? [])
        var lines: [String: [Substring]] = [:]
        func file(_ path: String, _ side: ThreadAnchor.Side) -> [Substring]? {
            let key = "\(side.rawValue):\(path)"
            if let cached = lines[key] { return cached }
            let text = side == .new ? contents[path]?.new : contents[path]?.old
            let split = text.map(TextLines.split)
            lines[key] = split
            return split
        }
        let placed = threads.threads(in: id).map { thread in
            let anchor = thread.anchor
            guard paths.contains(anchor.path), thread.github?.onFile != true,
                let text = file(anchor.path, anchor.side)
            else {
                return PlacedThread(thread: thread, placement: .notShown)
            }
            if let lines = anchor.locate(in: text) {
                return PlacedThread(thread: thread, placement: .lines(lines))
            }
            // A pull request comment whose hunk didn't show its lines was never placeable.
            if thread.source == .gitHub, anchor.text.isEmpty {
                return PlacedThread(thread: thread, placement: .notShown)
            }
            return PlacedThread(
                thread: thread, placement: isAfterShownCommits(thread) ? .later : .outdated)
        }
        .sorted { lhs, rhs in
            if lhs.thread.isResolved != rhs.thread.isResolved { return !lhs.thread.isResolved }
            if lhs.thread.anchor.path != rhs.thread.anchor.path {
                return ReviewDiffBuilder.precedesInTree(
                    lhs.thread.anchor.path, rhs.thread.anchor.path)
            }
            return lhs.thread.anchor.lines.lowerBound < rhs.thread.anchor.lines.lowerBound
        }
        placementCache.key = key
        placementCache.placed = placed
        return placed
    }

    /// Whether the thread's commit is newer than the newest commit picked in the list.
    private func isAfterShownCommits(_ thread: ReviewThread) -> Bool {
        guard let commit = thread.github?.commit,
            case .commit(let newest) = commitSelection?.newest,
            let ids = commitLog?.commits.map(\.id), let written = ids.firstIndex(of: commit),
            let shown = ids.firstIndex(of: newest)
        else { return false }
        return written < shown
    }

    /// The branch's commits up to the one a thread was written on, as its diff showed then; nil
    /// when that commit isn't on the branch any more, such as after a rebase.
    func commitsUpTo(_ thread: ReviewThread) -> CommitSelection? {
        guard let commit = thread.github?.commit, let log = commitLog,
            log.commits.contains(where: { $0.id == commit }), let oldest = log.commits.last
        else { return nil }
        return CommitSelection(newest: .commit(commit), oldest: .commit(oldest.id))
    }

    /// The file list's markers: each file's open and resolved threads, outdated ones included.
    var threadCountsByPath: [String: FileThreadCounts] {
        threadCounts { $0.anchor.path }
    }

    /// The commit list's markers: each row's threads, by the commit they were written on.
    var threadCountsByCommit: [CommitSelection.End: FileThreadCounts] {
        threadCounts(by: \.writtenOn)
    }

    private func threadCounts<Key: Hashable>(by key: (ReviewThread) -> Key?) -> [Key:
        FileThreadCounts]
    {
        var counts: [Key: FileThreadCounts] = [:]
        for thread in threads?.threads(in: id) ?? [] {
            guard let key = key(thread) else { continue }
            switch (thread.source == .gitHub, thread.isResolved) {
            case (false, true): counts[key, default: FileThreadCounts()].resolved += 1
            case (false, false): counts[key, default: FileThreadCounts()].open += 1
            case (true, true): counts[key, default: FileThreadCounts()].gitHubResolved += 1
            case (true, false): counts[key, default: FileThreadCounts()].gitHubOpen += 1
            }
        }
        return counts
    }

    /// The toolbar's badge: open threads, whether or not the diff shows them.
    var openThreadCount: Int {
        threads?.threads(in: id).count { !$0.isResolved } ?? 0
    }

    /// What the diff draws: placed threads, without resolved ones unless they're asked for.
    var threadMarkers: [String: [ThreadMarker]] {
        let showsResolved = services.settings.showsResolvedThreads
        let placedThreads = placedThreads
        guard threads != nil else { return [:] }
        let key = placementCache.key + [showsResolved ? 1 : 0]
        if placementCache.markersKey == key { return placementCache.markers }
        var markers: [String: [ThreadMarker]] = [:]
        for placed in placedThreads where showsResolved || !placed.thread.isResolved {
            guard let marker = Self.marker(placed) else { continue }
            markers[placed.thread.anchor.path, default: []].append(marker)
        }
        placementCache.markersKey = key
        placementCache.markers = markers
        return markers
    }

    /// One thread's marker, resolved or not; nil for a thread the diff has no lines for.
    func marker(for id: String) -> ThreadMarker? {
        placedThreads.first { $0.id == id }.flatMap(Self.marker)
    }

    private static func marker(_ placed: PlacedThread) -> ThreadMarker? {
        guard case .lines(let lines) = placed.placement, let latest = placed.thread.comments.last
        else { return nil }
        // The diff draws plain text: the Markdown's words, not its asterisks and backticks.
        let plain =
            (try? AttributedString(markdown: latest.body)).map { String($0.characters) }
            ?? latest.body
        let firstLine = plain.prefix { !$0.isNewline }
        return ThreadMarker(
            id: placed.id, side: placed.thread.anchor.side, lines: lines,
            latestAuthor: latest.author, latest: String(firstLine.prefix(120)),
            commentCount: placed.thread.comments.count, isResolved: placed.thread.isResolved,
            source: placed.thread.source)
    }

    /// The anchor `c` would comment on, with the lines' text from the file as it is.
    func anchor(path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>) -> ThreadAnchor? {
        let text = side == .new ? contents[path]?.new : contents[path]?.old
        return text.flatMap {
            ThreadAnchor(path: path, side: side, lines: lines, in: TextLines.split($0))
        }
    }
}
