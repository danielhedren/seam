import DiffModel
import Foundation
import SeamCore

package struct FileThreadCounts: Equatable {
    package var open = 0
    package var resolved = 0
    /// A pull request's threads, which get a dot of their own (SPEC §7.9).
    package var gitHubOpen = 0
    package var gitHubResolved = 0
}

/// Placements and markers per (threads, diff, contents) version: placing splits each file's text,
/// a marker parses its comment's Markdown, and the diff view asks for both on every update.
package final class ThreadPlacementCache {
    var key: [Int] = []
    var placed: [PlacedThread] = []
    var markersKey: [Int] = []
    var markers: [String: [ThreadMarker]] = [:]
}

extension WorktreeReview {
    /// The pull request's conversation as last read; nil without a PR, or with PRs off.
    package var conversation: PullRequestConversation? {
        pullRequestThreads?.conversation(in: id)
    }

    /// Seam's threads and the pull request's, this worktree's.
    var allThreads: [ReviewThread] {
        (threads?.threads(in: id) ?? []) + (pullRequestThreads?.threads(in: id) ?? [])
    }

    /// This worktree's threads with where they are now, open ones first, then by file and line.
    package var placedThreads: [PlacedThread] {
        guard threads != nil || pullRequestThreads != nil else { return [] }
        let key = [
            threads?.version ?? 0, pullRequestThreads?.version ?? 0, diffVersion, contentsVersion,
            services.settings.showsPullRequests ? 1 : 0,
        ]
        if placementCache.key == key { return placementCache.placed }
        var lines: [String: [Substring]] = [:]
        let contents = contents
        var newest: String?
        if case .commit(let id) = commitSelection?.newest { newest = id }
        let context = ThreadPlacer.Context(
            paths: Set(diff?.files.map(\.diff.path) ?? []),
            text: { path, side in
                let key = "\(side.rawValue):\(path)"
                if let cached = lines[key] { return cached }
                let text = side == .new ? contents[path]?.new : contents[path]?.old
                let split = text.map(TextLines.split)
                lines[key] = split
                return split
            },
            commits: commitLog?.commits.map(\.id) ?? [], newestShown: newest,
            renamed: Dictionary(
                (diff?.files ?? []).compactMap { file in
                    file.diff.oldPath.flatMap { $0 == file.diff.path ? nil : ($0, file.diff.path) }
                }, uniquingKeysWith: { first, _ in first }))
        let placed = ThreadPlacer.place(allThreads, in: context)
        placementCache.key = key
        placementCache.placed = placed
        return placed
    }

    /// The branch's commits up to the one a thread was written on, as its diff showed then; nil
    /// when that commit isn't on the branch any more, such as after a rebase.
    package func commitsUpTo(_ thread: ReviewThread) -> CommitSelection? {
        guard let commit = thread.github?.commit, let log = commitLog,
            log.commits.contains(where: { $0.id == commit }), let oldest = log.commits.last
        else { return nil }
        return CommitSelection(newest: .commit(commit), oldest: .commit(oldest.id))
    }

    /// The file list's markers: each file's open and resolved threads, outdated ones included.
    package var threadCountsByPath: [String: FileThreadCounts] {
        let paths = Dictionary(
            placedThreads.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        return threadCounts { paths[$0.id] ?? $0.anchor.path }
    }

    /// The commit list's markers: each row's threads, by the commit they were written on.
    package var threadCountsByCommit: [CommitSelection.End: FileThreadCounts] {
        threadCounts(by: \.writtenOn)
    }

    private func threadCounts<Key: Hashable>(by key: (ReviewThread) -> Key?) -> [Key:
        FileThreadCounts]
    {
        var counts: [Key: FileThreadCounts] = [:]
        // Notes ask no answer: they're no part of the open work the dots and badge count.
        for thread in allThreads where !thread.isNote {
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

    /// The threads Go › Next and Previous Thread step through, in file order: open ones, and
    /// resolved ones too while they're shown.
    package var steppableThreads: [PlacedThread] {
        let showsResolved = services.settings.showsResolvedThreads
        return placedThreads.filter { showsResolved || !$0.thread.isResolved }
            .sorted { lhs, rhs in
                if lhs.path != rhs.path {
                    return ReviewDiffBuilder.precedesInTree(lhs.path, rhs.path)
                }
                return lhs.thread.anchor.lines.lowerBound < rhs.thread.anchor.lines.lowerBound
            }
    }

    /// Seam's open threads whose latest word isn't the reader's: an agent's answer or question,
    /// waiting on them. A pull request's threads are answered on GitHub, so they aren't here.
    package var awaitingReply: [PlacedThread] {
        let reader = threads?.knownReader(in: id) ?? ReviewerIdentity(name: ReviewThread.reader)
        return placedThreads.filter { $0.thread.source == .seam && reader.awaitsReply($0.thread) }
    }

    /// What awaits the reader here, for the worktree's row and the Needs You sort (SPEC §7.2).
    /// Unlike `awaitingReply`, it needs no diff, so every row has it.
    package var attention: WorktreeAttention {
        let reader = threads?.knownReader(in: id) ?? ReviewerIdentity(name: ReviewThread.reader)
        return WorktreeAttention(
            awaiting: (threads?.threads(in: id) ?? []).count { reader.awaitsReply($0) },
            checksFailed: pullRequest.map { $0.state == .open && $0.ciFailed } ?? false)
    }

    /// The toolbar's badge: open threads, whether or not the diff shows them.
    package var openThreadCount: Int {
        allThreads.count { !$0.isResolved && !$0.isNote }
    }

    /// What the diff draws: placed threads, without resolved ones unless they're asked for.
    package var threadMarkers: [String: [ThreadMarker]] {
        let showsResolved = services.settings.showsResolvedThreads
        let placedThreads = placedThreads
        guard threads != nil || pullRequestThreads != nil else { return [:] }
        let key = placementCache.key + [showsResolved ? 1 : 0]
        if placementCache.markersKey == key { return placementCache.markers }
        var markers: [String: [ThreadMarker]] = [:]
        for placed in placedThreads where showsResolved || !placed.thread.isResolved {
            guard let marker = Self.marker(placed) else { continue }
            markers[placed.path, default: []].append(marker)
        }
        placementCache.markersKey = key
        placementCache.markers = markers
        return markers
    }

    /// One thread's marker, resolved or not; nil for a thread the diff has no lines for.
    /// Resolved threads while they're hidden, which still mark their lines, hollow (SPEC §7.7).
    package var hiddenResolvedMarkers: [String: [ThreadMarker]] {
        guard !services.settings.showsResolvedThreads else { return [:] }
        var markers: [String: [ThreadMarker]] = [:]
        for placed in placedThreads where placed.thread.isResolved {
            guard let marker = Self.marker(placed) else { continue }
            markers[placed.path, default: []].append(marker)
        }
        return markers
    }

    func marker(for id: String) -> ThreadMarker? {
        placedThreads.first { $0.id == id }.flatMap(Self.marker)
    }

    private static func marker(_ placed: PlacedThread) -> ThreadMarker? {
        guard case .lines(let lines) = placed.placement, let latest = placed.thread.comments.last
        else { return nil }
        // The diff draws plain text: the Markdown's words, not its asterisks and backticks.
        // Foundation on Linux can't parse Markdown, so there the text stays as written.
        #if canImport(Darwin)
            let plain =
                (try? AttributedString(markdown: latest.body)).map { String($0.characters) }
                ?? latest.body
        #else
            let plain = latest.body
        #endif
        let firstLine = plain.prefix { !$0.isNewline }
        return ThreadMarker(
            id: placed.id, side: placed.thread.anchor.side, lines: lines,
            latestAuthor: latest.author, latest: String(firstLine.prefix(120)),
            commentCount: placed.thread.comments.count, isResolved: placed.thread.isResolved,
            source: placed.thread.source, isNote: placed.thread.isNote,
            title: placed.thread.cardTitle(placement: placed.placement))
    }

    /// The anchor `c` would comment on, with the lines' text from the file as it is.
    func anchor(path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>) -> ThreadAnchor? {
        // Old lines of a file shown since viewed are the reader's earlier copy, not the base.
        guard side == .new || sinceViewed[path] == nil else { return nil }
        let text = side == .new ? contents[path]?.new : contents[path]?.old
        return text.flatMap {
            ThreadAnchor(path: path, side: side, lines: lines, in: TextLines.split($0))
        }
    }
}

/// What in a worktree is the reader's to act on: threads whose latest word isn't theirs (an
/// agent's answer or question), and an open pull request's failed checks.
package struct WorktreeAttention: Equatable {
    var awaiting = 0
    var checksFailed = false

    var needsReader: Bool { awaiting > 0 || checksFailed }

    /// "2 awaiting you · checks failed"; nil when nothing does.
    package var summary: String? {
        var parts: [String] = []
        if awaiting > 0 {
            parts.append(String(localized: "\(awaiting) awaiting you", bundle: .module))
        }
        if checksFailed { parts.append(String(localized: "checks failed", bundle: .module)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
