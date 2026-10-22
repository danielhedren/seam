import SeamCore
import SwiftUI

struct WorktreeList: View {
    let session: RepoSession

    var body: some View {
        List(selection: Binding(get: { session.selectedID }, set: { session.select($0) })) {
            ForEach(session.sortedReviews) { review in
                WorktreeRow(review: review).tag(review.id)
            }
        }
        .contextMenu {
            Picker(String(localized: "Sort By", bundle: .module), selection: Bindable(session).sort)
            {
                Text("Recently Changed", bundle: .module).tag(WorktreeSort.recent)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(review.worktree.name).bold().lineLimit(1).truncationMode(.middle)
            if let branch = review.worktree.branch, branch != review.worktree.name {
                Text(branch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                if let commits = review.uniqueCommitCount {
                    Text(verbatim: "+\(commits)").monospacedDigit()
                }
                if let files = review.activity?.uncommittedFiles, files > 0 {
                    Text(verbatim: "✎\(files)").monospacedDigit()
                }
                ForEach(markers, id: \.self) { marker in
                    Text(marker).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let date = review.lastChange {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(review.worktree.isMissing ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
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

    private var accessibilityText: String {
        var parts = [review.worktree.name]
        if let branch = review.worktree.branch, branch != review.worktree.name {
            parts.append(branch)
        }
        if let commits = review.uniqueCommitCount {
            parts.append(String(localized: "\(commits) commits ahead", bundle: .module))
        }
        if let files = review.activity?.uncommittedFiles {
            parts.append(String(localized: "\(files) uncommitted files", bundle: .module))
        }
        return (parts + markers).joined(separator: ", ")
    }
}
