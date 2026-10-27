import ReviewModel
import SeamCore
import SwiftUI

struct WorktreeList: View {
    let session: RepoSession

    var body: some View {
        List(selection: Binding(get: { session.selectedID }, set: { session.select($0) })) {
            Section {
                ForEach(session.sortedReviews) { review in
                    WorktreeRow(review: review).tag(review.id)
                }
            } header: {
                Text(verbatim: session.repositoryName).lineLimit(1).truncationMode(.middle)
                    .help(session.directory.path)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let review = session.reviews.first(where: { ids.contains($0.id) }) {
                ActionMenu(groups: RowActions.actions(for: review, in: session))
                Divider()
            }
            Picker(String(localized: "Sort By", bundle: .module), selection: Bindable(session).sort)
            {
                Text("Needs You First", bundle: .module).tag(WorktreeSort.attention)
                Text("Recent Change", bundle: .module).tag(WorktreeSort.recent)
                Text("Name", bundle: .module).tag(WorktreeSort.name)
            }
            Toggle(
                String(localized: "Hide Missing Worktrees", bundle: .module),
                isOn: Bindable(session).hidesMissing)
        }
    }
}

struct WorktreeRow: View {
    let review: WorktreeReview
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(review.worktree.name).bold().lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let date = review.lastChange {
                    AgeText(date: date).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let branch = review.worktree.branch, branch != review.worktree.name {
                Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            // In words, on a line of its own: it's what the reader scans the list for.
            if let attention = review.attention.summary {
                Text(verbatim: attention).font(.caption.weight(.semibold))
                    .foregroundStyle(tint(.orange)).lineLimit(1)
            }
            if hasDetails {
                HStack(spacing: 6) {
                    if !summary.isEmpty { Text(summary).lineLimit(1) }
                    if uncommittedFiles > 0 {
                        Text(verbatim: "✎\(uncommittedFiles)")
                            .help(Counted.uncommittedFiles(uncommittedFiles))
                    }
                    ForEach(markers, id: \.self) { marker in
                        Text(marker).foregroundStyle(tint(.orange))
                    }
                    if let pullRequest = review.pullRequest {
                        PullRequestBadge(
                            pullRequest: pullRequest, unpushed: review.unpushedCount,
                            read: review.pullRequests?.saved.read)
                    }
                    Spacer(minLength: 0)
                    if let changes = review.activity?.changes, changes.files > 0 {
                        Text(verbatim: "+\(changes.additions)")
                            .foregroundStyle(changes.additions > 0 ? tint(.green) : grey)
                        Text(verbatim: "−\(changes.deletions)")
                            .foregroundStyle(changes.deletions > 0 ? tint(.red) : grey)
                    }
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(review.worktree.isMissing ? 0.5 : 1)
    }

    /// Green, red and orange are unreadable on a selected row's accent fill; the signs and words
    /// still carry the meaning there.
    private var grey: AnyShapeStyle { AnyShapeStyle(.secondary) }

    private func tint(_ color: Color) -> AnyShapeStyle {
        prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(color)
    }

    private var uncommittedFiles: Int { review.activity?.uncommittedFiles ?? 0 }

    /// A row level with its base and in no special state is just its name.
    private var hasDetails: Bool {
        !summary.isEmpty || uncommittedFiles > 0 || !markers.isEmpty || review.pullRequest != nil
    }

    /// "5 commits · 19 files": what the branch adds, against its base.
    private var summary: String {
        // A worktree level with its base says nothing here rather than "0 commits · 0 files".
        var parts: [String] = []
        if let commits = review.uniqueCommitCount, commits > 0 {
            parts.append(Counted.commits(commits))
        }
        if let files = review.activity?.changes?.files, files > 0 {
            parts.append(Counted.files(files))
        }
        return parts.joined(separator: " · ")
    }

    private var markers: [String] {
        var markers: [String] = []
        let worktree = review.worktree
        if worktree.isDetached { markers.append(String(localized: "detached", bundle: .module)) }
        if worktree.isLocked { markers.append(String(localized: "locked", bundle: .module)) }
        if worktree.isPrunable { markers.append(String(localized: "prunable", bundle: .module)) }
        if worktree.isMissing { markers.append(String(localized: "missing", bundle: .module)) }
        if review.staleParent != nil {
            markers.append(String(localized: "stale parent", bundle: .module))
        }
        return markers
    }
}
