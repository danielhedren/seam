import SeamCore
import SwiftUI

/// `⌘K`: fuzzy search over worktree and branch names (SPEC §7.2). The highlighted match is the
/// one Return opens; ↑ and ↓ move it, as in the command palette.
struct WorktreeSwitcher: View {
    let session: RepoSession
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let matches = Self.matches(query, in: session.sortedReviews)
        VStack(spacing: 0) {
            TextField(
                String(localized: "Search worktrees and branches", bundle: .module), text: $query
            )
            .textFieldStyle(.plain)
            .font(.title3)
            .padding(12)
            .focused($fieldFocused)
            .onSubmit { pick(matches.first { $0.id == selection } ?? matches.first) }
            .onKeyPress(.downArrow) {
                selection = Self.moved(selection, by: 1, in: matches.map(\.id))
                return .handled
            }
            .onKeyPress(.upArrow) {
                selection = Self.moved(selection, by: -1, in: matches.map(\.id))
                return .handled
            }
            Divider()
            ScrollViewReader { scroller in
                List(matches, selection: $selection) { review in
                    SwitcherRow(review: review)
                        .contentShape(Rectangle())
                        .onTapGesture { pick(review) }
                        .tag(review.id)
                }
                .onChange(of: selection) { scroller.scrollTo(selection) }
            }
            .overlay {
                if matches.isEmpty {
                    Text("No worktree or branch matches “\(query)”", bundle: .module)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(height: 280)
        }
        .frame(width: 440)
        .onAppear {
            fieldFocused = true
            selection = matches.first?.id
        }
        .onChange(of: query) {
            selection = Self.matches(query, in: session.sortedReviews).first?.id
        }
        .onExitCommand { session.showsSwitcher = false }
    }

    /// Best match first; ties keep the sidebar's order.
    static func matches(_ query: String, in reviews: [WorktreeReview]) -> [WorktreeReview] {
        reviews
            .enumerated()
            .compactMap { position, review -> (WorktreeReview, Int, Int)? in
                let name = FuzzyMatch.score(query, in: review.worktree.name)
                let branch = review.worktree.branch.flatMap { FuzzyMatch.score(query, in: $0) }
                guard let best = [name, branch].compactMap(\.self).max() else { return nil }
                return (review, best, position)
            }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }

    /// The highlight `delta` rows on, stopping at either end.
    static func moved(_ selection: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        let current = selection.flatMap(ids.firstIndex(of:)) ?? 0
        return ids[min(max(current + delta, 0), ids.count - 1)]
    }

    private func pick(_ review: WorktreeReview?) {
        guard let review else { return }
        session.select(review.id)
        session.showsSwitcher = false
        session.diff.focus()
    }
}

private struct SwitcherRow: View {
    let review: WorktreeReview

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(review.worktree.name).bold().lineLimit(1).truncationMode(.middle)
            if let branch = review.worktree.branch, branch != review.worktree.name {
                Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .opacity(review.worktree.isMissing ? 0.5 : 1)
    }
}
