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
            HStack(spacing: 6) {
                Text(summary).lineLimit(1)
                if let files = review.activity?.uncommittedFiles, files > 0 {
                    Text(verbatim: "✎\(files)")
                }
                ForEach(markers, id: \.self) { marker in
                    Text(marker).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
                if let changes = review.activity?.changes, changes.files > 0 {
                    Text(verbatim: "+\(changes.additions)").foregroundStyle(.green)
                    Text(verbatim: "−\(changes.deletions)").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .opacity(review.worktree.isMissing ? 0.5 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "5 commits · 19 files": what the branch adds, against its base.
    private var summary: String {
        var parts: [String] = []
        if let commits = review.uniqueCommitCount {
            parts.append(
                commits == 1
                    ? String(localized: "1 commit", bundle: .module)
                    : String(localized: "\(commits) commits", bundle: .module))
        }
        if let files = review.activity?.changes?.files {
            parts.append(
                files == 1
                    ? String(localized: "1 file", bundle: .module)
                    : String(localized: "\(files) files", bundle: .module))
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

    private var accessibilityText: String {
        var parts = [review.worktree.name]
        if let branch = review.worktree.branch, branch != review.worktree.name {
            parts.append(branch)
        }
        if let commits = review.uniqueCommitCount {
            parts.append(String(localized: "\(commits) commits ahead", bundle: .module))
        }
        if let changes = review.activity?.changes {
            parts.append(
                String(
                    localized:
                        "\(changes.files) files changed, \(changes.additions) lines added, \(changes.deletions) removed",
                    bundle: .module))
        }
        if let files = review.activity?.uncommittedFiles {
            parts.append(String(localized: "\(files) uncommitted files", bundle: .module))
        }
        return (parts + markers).joined(separator: ", ")
    }
}
