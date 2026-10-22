import DiffView
import Foundation
import SeamCore

/// Where a thread is in the diff as it is now (SPEC §7.7).
enum ThreadPlacement: Equatable {
    case lines(ClosedRange<Int>)
    /// Its lines are gone from the file.
    case outdated
    /// Its file isn't in this diff, or its text isn't loaded.
    case notShown
}

struct PlacedThread: Equatable, Identifiable {
    var thread: ReviewThread
    var placement: ThreadPlacement

    var id: String { thread.id }
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
        let key = [threads.version, diffVersion, contentsVersion]
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
            guard paths.contains(anchor.path), let text = file(anchor.path, anchor.side) else {
                return PlacedThread(thread: thread, placement: .notShown)
            }
            return PlacedThread(
                thread: thread,
                placement: anchor.locate(in: text).map(ThreadPlacement.lines) ?? .outdated)
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

    /// What the diff draws: placed threads, without resolved ones unless they're asked for.
    var threadMarkers: [String: [ThreadMarker]] {
        let showsResolved = services.settings.showsResolvedThreads
        let placedThreads = placedThreads
        guard threads != nil else { return [:] }
        let key = placementCache.key + [showsResolved ? 1 : 0]
        if placementCache.markersKey == key { return placementCache.markers }
        var markers: [String: [ThreadMarker]] = [:]
        for placed in placedThreads {
            guard case .lines(let lines) = placed.placement,
                showsResolved || !placed.thread.isResolved,
                let latest = placed.thread.comments.last
            else { continue }
            // The diff draws plain text: the Markdown's words, not its asterisks and backticks.
            let plain =
                (try? AttributedString(markdown: latest.body)).map {
                    String($0.characters)
                } ?? latest.body
            let firstLine = plain.prefix { !$0.isNewline }
            markers[placed.thread.anchor.path, default: []].append(
                ThreadMarker(
                    id: placed.id, side: placed.thread.anchor.side, lines: lines,
                    latestAuthor: latest.author, latest: String(firstLine.prefix(120)),
                    commentCount: placed.thread.comments.count,
                    isResolved: placed.thread.isResolved))
        }
        placementCache.markersKey = key
        placementCache.markers = markers
        return markers
    }

    /// The anchor `c` would comment on, with the lines' text from the file as it is.
    func anchor(path: String, side: ThreadAnchor.Side, lines: ClosedRange<Int>) -> ThreadAnchor? {
        let text = side == .new ? contents[path]?.new : contents[path]?.old
        return text.flatMap {
            ThreadAnchor(path: path, side: side, lines: lines, in: TextLines.split($0))
        }
    }
}
