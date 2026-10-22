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
                    if uncommittedFiles > 0 {
                        WorkingTreeRow(files: uncommittedFiles)
                            .tag(CommitSelection.End.workingTree)
                    }
                    ForEach(log.commits) { commit in
                        CommitRow(commit: commit).tag(CommitSelection.End.commit(commit.id))
                    }
                    if log.isTruncated {
                        Text("Older commits not shown", bundle: .module)
                            .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                    }
                    Button {
                        session.showsBasePicker.toggle()
                    } label: {
                        BaseRow(commit: log.base, parent: review.parentName)
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    .help(String(localized: "Choose what to compare with (b)", bundle: .module))
                    .popover(isPresented: Bindable(session).showsBasePicker, arrowEdge: .trailing) {
                        BasePicker(session: session, review: review)
                    }
                } header: {
                    header(log)
                }
            }
        } else {
            Text("Commits", bundle: .module).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var uncommittedFiles: Int { review.activity?.uncommittedFiles ?? 0 }

    private func header(_ log: CommitLog) -> some View {
        HStack {
            Text(verbatim: Counted.commits(log.commits.count))
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
                let showsWorkingTree = uncommittedFiles > 0
                guard
                    let run = log.selection(
                        spanning: picked.filter { showsWorkingTree || $0 != .workingTree },
                        showsWorkingTree: showsWorkingTree)
                else { return }
                session.selectCommits(run)
            })
    }
}

struct WorkingTreeRow: View {
    let files: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uncommitted changes", bundle: .module)
                Text(verbatim: Counted.files(files)).font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "pencil")
        }
    }
}

struct CommitRow: View {
    let commit: ReviewCommit

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(commit.shortID).monospaced()
                    AgeText(date: commit.date)
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
struct BaseRow: View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.up.chevron.down").font(.caption)
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .help(commit.subject)
        .accessibilityElement(children: .combine)
    }
}
