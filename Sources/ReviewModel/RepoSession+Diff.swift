import DiffModel
import Foundation
import SeamCore

/// Everything the diff's drawing depends on for one worktree, as one comparable value: the diff
/// view is given new content only when this changes, so state that changes the drawing must be
/// in it, or the screen stays behind the model.
package struct DiffShown: Equatable {
    var id: String
    var version: Int
    var range: Int
    var narrowing: Narrowing
    var threads: [String: [ThreadMarker]]
    var resolvedMarks: [String: [ThreadMarker]]
    var preamble: [ThreadMarker]
    var sinceViewed: [String: String]
    var mode: DiffLayoutMode
    var collapsed: Set<String>
    var contentsVersion: Int
    var syntaxVersion: Int
    var wraps: Bool
    var showsReturns: Bool
    var viewed: ViewedMarks
    var expansions: [String: [Int: GapExpansion]]
    var draft: DraftMarker?
    var openThread: ThreadMarker?
}

extension RepoSession {
    package func diffShown(for review: WorktreeReview) -> DiffShown {
        DiffShown(
            id: review.id, version: review.diffVersion, range: review.shownRangeVersion,
            narrowing: review.narrowing, threads: review.threadMarkers,
            resolvedMarks: review.hiddenResolvedMarkers, preamble: review.preambleMarkers,
            sinceViewed: review.sinceViewed,
            mode: review.mode, collapsed: review.collapsed,
            contentsVersion: review.contentsVersion, syntaxVersion: review.syntaxVersion,
            wraps: review.wraps, showsReturns: settings.showsCarriageReturns,
            viewed: review.viewed, expansions: review.expansions, draft: draftMarker(for: review),
            openThread: openThreadMarker(for: review))
    }

    /// What the diff draws for `review` after showing `previous`, and where it scrolls; nil until
    /// the diff has loaded, or when the worktree's folder went missing.
    package func diffUpdate(for review: WorktreeReview, after previous: DiffShown?)
        -> (content: DiffContent, position: DiffPosition)?
    {
        guard var content = review.content else { return nil }
        let shown = diffShown(for: review)
        let position: DiffPosition =
            if previous?.id == review.id {
                previous?.range == shown.range && previous?.narrowing == shown.narrowing
                    ? .keep : threadJumps.removeValue(forKey: review.id).map { .thread($0) } ?? .top
            } else if let anchor = review.savedAnchor {
                .anchor(anchor)
            } else {
                .top
            }
        content.draft = shown.draft
        if let open = shown.openThread {
            let path = review.placedThreads.first { $0.id == open.id }?.path
            let isShown =
                content.preamble.contains { $0.id == open.id }
                || content.threads[path ?? ""]?.contains { $0.id == open.id } == true
            // A resolved thread shows while it's open, even with resolved threads hidden.
            if !isShown {
                if let path, content.review.files.contains(where: { $0.diff.path == path }) {
                    content.threads[path, default: []].append(open)
                } else {
                    content.preamble.append(open)
                }
            }
            if let path { content.resolvedMarks[path]?.removeAll { $0.id == open.id } }
            content.openThread = open.id
        }
        return (content, position)
    }
}
