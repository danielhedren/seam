import SeamCore
import SwiftUI

/// The toolbar's "vs <parent>" control and its candidate list (SPEC §5.3).
/// The parents a worktree can be compared with (SPEC §5.3), shown from the commit list's base row.
struct BasePicker: View {
    let session: RepoSession
    let review: WorktreeReview
    @State private var otherRef = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compare against", bundle: .module).font(.headline)
            ForEach(review.detection?.candidates ?? [], id: \.ref) { candidate in
                Button {
                    session.setBaseOverride(candidate.ref)
                    session.showsBasePicker = false
                } label: {
                    HStack {
                        Image(systemName: "checkmark").opacity(isCurrent(candidate) ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(candidate.name)
                        Spacer()
                        Text("\(candidate.commitCount) commits", bundle: .module)
                            .foregroundStyle(.secondary).monospacedDigit()
                        if candidate.ref == review.detection?.parent?.ref {
                            Text("detected", bundle: .module).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent(candidate) ? .isSelected : [])
            }
            Divider()
            HStack {
                TextField(String(localized: "Other ref", bundle: .module), text: $otherRef)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useOtherRef)
                Button(String(localized: "Use", bundle: .module), action: useOtherRef)
                    .disabled(otherRef.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 340)
    }

    private func isCurrent(_ candidate: ParentCandidate) -> Bool {
        candidate.ref == (review.baseOverride ?? review.detection?.parent?.ref)
    }

    private func useOtherRef() {
        guard !otherRef.isEmpty else { return }
        let name = otherRef
        session.showsBasePicker = false
        otherRef = ""
        Task { await session.setTypedBase(name) }
    }
}

/// `⌘K`: fuzzy search over worktree and branch names (SPEC §7.2).
struct WorktreeSwitcher: View {
    let session: RepoSession
    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let matches = ranked
        VStack(spacing: 0) {
            TextField(String(localized: "Switch to worktree", bundle: .module), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { pick(matches.first) }
            Divider()
            List(matches) { review in
                Button {
                    pick(review)
                } label: {
                    VStack(alignment: .leading) {
                        Text(review.worktree.name).bold()
                        if let branch = review.worktree.branch {
                            Text(branch).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 280)
        }
        .frame(width: 440)
        .onAppear { fieldFocused = true }
        .onExitCommand { session.showsSwitcher = false }
    }

    private var ranked: [WorktreeReview] {
        session.sortedReviews
            .compactMap { review -> (WorktreeReview, Int)? in
                let name = FuzzyMatch.score(query, in: review.worktree.name)
                let branch = review.worktree.branch.flatMap { FuzzyMatch.score(query, in: $0) }
                guard let best = [name, branch].compactMap(\.self).max() else { return nil }
                return (review, best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private func pick(_ review: WorktreeReview?) {
        guard let review else { return }
        session.select(review.id)
        session.showsSwitcher = false
        session.diff.focus()
    }
}
