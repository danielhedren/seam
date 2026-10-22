import SeamCore
import SwiftUI

/// The selected worktree's commits under the worktree list (SPEC §7.2.1). Selecting rows picks
/// what the diff covers; a selection always spans whole runs of rows, so ⌘-click fills the gap.
struct CommitList: View {
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        if let log = review.commitLog {
            List(selection: selection(log)) {
                Section {
                    WorkingTreeRow(files: review.activity?.uncommittedFiles ?? 0)
                        .tag(CommitSelection.End.workingTree)
                    ForEach(log.commits) { commit in
                        CommitRow(commit: commit).tag(CommitSelection.End.commit(commit.id))
                    }
                    if log.isTruncated {
                        Text("Older commits not shown", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                    }
                    BaseRow(commit: log.base, parent: review.parentName).selectionDisabled()
                } header: {
                    header(log)
                }
            }
        } else {
            Text("Commits", bundle: .module).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ log: CommitLog) -> some View {
        HStack {
            Text("\(log.commits.count) commits", bundle: .module)
            Spacer()
            if review.commitSelection != nil {
                Button(String(localized: "Show All", bundle: .module)) {
                    session.setScope(.all)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(String(localized: "Show all changes (1)", bundle: .module))
            }
        }
    }

    private func selection(_ log: CommitLog) -> Binding<Set<CommitSelection.End>> {
        let ends = log.ends
        return Binding(
            get: {
                guard let shown = review.shownSelection,
                    let newest = ends.firstIndex(of: shown.newest),
                    let oldest = ends.firstIndex(of: shown.oldest), newest <= oldest
                else { return [] }
                return Set(ends[newest...oldest])
            },
            set: { picked in
                let indices = picked.compactMap { ends.firstIndex(of: $0) }
                guard let newest = indices.min(), let oldest = indices.max() else { return }
                session.selectCommits(CommitSelection(newest: ends[newest], oldest: ends[oldest]))
            })
    }
}

private struct WorkingTreeRow: View {
    let files: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uncommitted changes", bundle: .module)
                Text(
                    files == 0
                        ? String(localized: "None", bundle: .module)
                        : String(localized: "\(files) files", bundle: .module)
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "pencil")
        }
    }
}

private struct CommitRow: View {
    let commit: ReviewCommit

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(commit.shortID).monospaced()
                    Text(
                        commit.date, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.secondary)
        }
        .help(commit.subject)
        .accessibilityElement(children: .combine)
    }
}

/// The commit the review starts from; not selectable, since every diff is measured from it.
private struct BaseRow: View {
    let commit: ReviewCommit
    let parent: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    parent.map { String(localized: "Branched from \($0)", bundle: .module) }
                        ?? String(localized: "Base", bundle: .module)
                )
                .bold()
                Text(verbatim: "\(commit.shortID) \(commit.subject)").lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .help(commit.subject)
        .accessibilityElement(children: .combine)
    }
}
