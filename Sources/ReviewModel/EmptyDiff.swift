import Foundation
import SeamCore

/// What the diff says when it shows nothing: why, and what to do about it (SPEC §9).
package struct EmptyDiff: Equatable {
    package enum Action: Equatable {
        case clearFilter
        case clearSearch
        case showAll
    }

    package var title: String
    package var detail: String
    package var systemImage: String
    package var action: Action?

    @MainActor
    package static func of(_ review: WorktreeReview) -> EmptyDiff? {
        guard let diff = review.diff, review.problem == nil else { return nil }
        if !diff.files.isEmpty, review.isSearching {
            if review.searchIsInvalid {
                return EmptyDiff(
                    title: String(localized: "Invalid regular expression", bundle: .module),
                    detail: String(
                        localized: "“\(review.appliedSearch.text)” doesn't compile.",
                        bundle: .module),
                    systemImage: "exclamationmark.magnifyingglass", action: .clearSearch)
            }
            guard review.searchResult?.files.isEmpty == true else { return nil }
            return EmptyDiff(
                title: String(localized: "No results", bundle: .module),
                detail: String(
                    localized: "Nothing in the diff matches “\(review.appliedSearch.text)”.",
                    bundle: .module),
                systemImage: "magnifyingglass", action: .clearSearch)
        }
        if !diff.files.isEmpty {
            let filter = FileFilter(review.diffFilter)
            guard !filter.isEmpty, !diff.files.contains(where: { filter.matches($0.diff.path) })
            else { return nil }
            return EmptyDiff(
                title: String(localized: "No matching files", bundle: .module),
                detail: String(
                    localized: "No changed file's path matches “\(review.diffFilter)”.",
                    bundle: .module),
                systemImage: "line.3.horizontal.decrease.circle", action: .clearFilter)
        }
        let parent = review.parentName ?? String(localized: "the base", bundle: .module)
        // Offered only when the All scope would show something.
        let showAll: Action? = (review.activity?.changes?.files ?? 0) > 0 ? .showAll : nil
        if review.commitSelection != nil {
            return EmptyDiff(
                title: String(localized: "No changes in the selected commits", bundle: .module),
                detail: String(
                    localized: "Together they leave every file as it was.",
                    bundle: .module),
                systemImage: "checkmark.circle", action: showAll)
        }
        switch review.scope {
        case .all:
            return EmptyDiff(
                title: String(localized: "No changes against \(parent)", bundle: .module),
                detail: String(
                    localized: "Changes show here as soon as files in this worktree are edited.",
                    bundle: .module),
                systemImage: "checkmark.circle", action: nil)
        case .committed:
            return EmptyDiff(
                title: String(localized: "No commits since \(parent)", bundle: .module),
                detail: String(
                    localized: "Commits on this branch show here once there are some.",
                    bundle: .module),
                systemImage: "checkmark.circle", action: showAll)
        case .uncommitted:
            return EmptyDiff(
                title: String(localized: "No uncommitted changes", bundle: .module),
                detail: String(
                    localized: "The working tree matches the branch's latest commit.",
                    bundle: .module),
                systemImage: "checkmark.circle", action: showAll)
        }
    }
}
