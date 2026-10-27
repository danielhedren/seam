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
        readThreadSince(placed, key: key)
        return placed
    }

    /// Reads the file each outdated thread was written on and diffs it with the file now, so
    /// its card can show what became of its lines and sit where they'd be. A thread written on
    /// uncommitted changes, or on the old side, has no such file; its card quotes its lines.
    private func readThreadSince(_ placed: [PlacedThread], key: [Int]) {
        guard key != threadSinceKey else { return }
        threadSinceKey = key
        let wanted = placed.compactMap { placed -> (String, ThreadAnchor, String, String)? in
            let thread = placed.thread
            guard placed.placement == .outdated || placed.placement == .later,
                thread.anchor.side == .new,
                let commit = thread.github?.commit
                    ?? (thread.uncommitted == true ? nil : thread.commit),
                let now = contents[placed.path]?.new
            else { return nil }
            return (thread.id, thread.anchor, commit, now)
        }
        let git = services.git
        let directory = worktree.path
        Task { [weak self] in
            var found: [String: ThreadSince] = [:]
            for (id, anchor, commit, now) in wanted {
                guard
                    let then = try? await git.string(
                        ["show", "\(commit):\(anchor.path)"], in: directory),
                    let since = ThreadSince.change(of: anchor, from: then, to: now)
                else { continue }
                found[id] = since
            }
            guard let self, self.threadSinceKey == key else { return }
            self.setThreadSince(found)
        }
    }

    /// The branch's commits up to the one a thread was written on, as its diff showed then; nil
    /// when that commit isn't on the branch any more, such as after a rebase.
    package func commitsUpTo(_ thread: ReviewThread) -> CommitSelection? {
        guard case .commit(let commit) = thread.writtenOn, let log = commitLog,
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
        let key = placementCache.key + [showsResolved ? 1 : 0, threadSince.count]
        if placementCache.markersKey == key { return placementCache.markers }
        var markers: [String: [ThreadMarker]] = [:]
        let paths = diffPaths
        for placed in placedThreads
        where paths.contains(placed.path) && (showsResolved || !placed.thread.isResolved) {
            guard let marker = marker(placed, inDiff: paths) else { continue }
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
        let paths = diffPaths
        for placed in placedThreads where placed.thread.isResolved && placed.isInDiff {
            guard let marker = marker(placed, inDiff: paths) else { continue }
            markers[placed.path, default: []].append(marker)
        }
        return markers
    }

    /// The id of the pull request conversation's card, which opens like a thread's.
    package static let conversationID = "conversation"

    /// The cards above the first file (SPEC §7.7): the pull request's conversation, then
    /// threads on files the diff doesn't show, each naming its file.
    package var preambleMarkers: [ThreadMarker] {
        let showsResolved = services.settings.showsResolvedThreads
        let paths = diffPaths
        let threads = placedThreads.filter { placed in
            !paths.contains(placed.path) && (showsResolved || !placed.thread.isResolved)
        }
        return [conversationMarker].compactMap { $0 }
            + threads.compactMap { marker($0, inDiff: paths) }
    }

    package func marker(for id: String) -> ThreadMarker? {
        if id == Self.conversationID { return conversationMarker }
        return placedThreads.first { $0.id == id }.flatMap { marker($0, inDiff: diffPaths) }
    }

    private var diffPaths: Set<String> { Set(diff?.files.map(\.diff.path) ?? []) }

    private var conversationMarker: ThreadMarker? {
        guard let conversation, let latest = conversation.items.last else { return nil }
        let verdict = PullRequestText.verdict(latest.kind).map { "\($0) " } ?? ""
        return ThreadMarker(
            id: Self.conversationID, side: .new, lines: 1...1, latestAuthor: latest.author,
            latest: verdict + Self.firstLine(latest.body),
            commentCount: conversation.items.count, isResolved: false, source: .gitHub,
            title: String(
                localized:
                    "Conversation on #\(String(conversation.pullRequest)) · \(Counted.comments(conversation.items.count))",
                bundle: .module),
            spot: .file)
    }

    /// A thread's card: on its lines, under its file's header when the diff has no lines for
    /// it, or above the first file, naming the file, when the diff doesn't show the file.
    private func marker(_ placed: PlacedThread, inDiff paths: Set<String>) -> ThreadMarker? {
        guard let latest = placed.thread.comments.last else { return nil }
        var lines = placed.thread.anchor.lines
        var title = placed.thread.cardTitle(placement: placed.placement)
        var spot = ThreadMarker.Spot.near
        if case .lines(let now) = placed.placement {
            lines = now
            spot = .lines
        } else {
            if let location = placed.location { title += " · \(location)" }
            if !paths.contains(placed.path) { title = "\(placed.path) · \(title)" }
            if placed.thread.github?.onFile == true { spot = .file }
            if let line = threadSince[placed.id]?.line { lines = line...line }
        }
        return ThreadMarker(
            id: placed.id, side: placed.thread.anchor.side, lines: lines,
            latestAuthor: latest.author, latest: Self.firstLine(latest.body),
            commentCount: placed.thread.comments.count, isResolved: placed.thread.isResolved,
            source: placed.thread.source, isNote: placed.thread.isNote, title: title, spot: spot)
    }

    /// The diff draws plain text: the Markdown's words, not its asterisks and backticks.
    /// Foundation on Linux can't parse Markdown, so there the text stays as written.
    private static func firstLine(_ markdown: String) -> String {
        #if canImport(Darwin)
            let plain =
                (try? AttributedString(markdown: markdown)).map { String($0.characters) }
                ?? markdown
        #else
            let plain = markdown
        #endif
        return String(plain.prefix { !$0.isNewline }.prefix(120))
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
