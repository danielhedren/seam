import SeamCore
import SwiftUI

/// The selected worktree's commits under the worktree list (SPEC §7.2.1). Selecting rows picks
/// what the diff covers; a selection always spans whole runs of rows, so ⌘-click fills the gap.
struct CommitList: View {
    let session: RepoSession
    let review: WorktreeReview

    var body: some View {
        // A log loaded before the directory or the chosen base went is no longer true.
        if let log = review.commitLog, Self.status(of: review)?.keepsLog ?? true {
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
                    .help(
                        CommandCatalog.help(
                            String(localized: "Choose Base", bundle: .module),
                            command: "base")
                    )
                    .modifier(BasePickerPopover(session: session, review: review))
                } header: {
                    header(log)
                }
            }
            .contextMenu(forSelectionType: CommitSelection.End.self) { picked in
                ActionMenu(groups: RowActions.actions(for: picked, of: review, in: session))
            }
        } else {
            placeholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
        }
    }

    /// Says why there are no commits; the diff's banner carries the details and fixes.
    @ViewBuilder private var placeholder: some View {
        switch Self.status(of: review) {
        case nil:
            Color.clear
        case .loading:
            ProgressView().controlSize(.small)
        case .missingDirectory:
            message(String(localized: "The worktree's directory is missing", bundle: .module))
        case .failed:
            message(String(localized: "Couldn't read the commits", bundle: .module))
        case .baseGone(let ref):
            VStack(spacing: 6) {
                message(String(localized: "The base \(ref) no longer exists", bundle: .module))
                // Without a base row, `b` and Review › Choose Base… open the picker from here.
                Button(String(localized: "Choose Base…", bundle: .module)) {
                    session.showsBasePicker.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)
                .modifier(BasePickerPopover(session: session, review: review))
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    enum Status: Equatable {
        case loading, missingDirectory, failed
        case baseGone(String)

        var keepsLog: Bool { self == .loading || self == .failed }
    }

    /// What the list says while it has no commits; nil while a load is too young to mention.
    static func status(of review: WorktreeReview) -> Status? {
        switch review.problem {
        case .missingDirectory: .missingDirectory
        case .overrideGone(let ref): .baseGone(ref)
        case .gitFailed: .failed
        case .editorFailed, nil: review.showsProgress ? .loading : nil
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
                .help(
                    CommandCatalog.help(
                        String(localized: "Show all changes", bundle: .module),
                        command: "scope-all"))
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
        VStack(alignment: .leading, spacing: 2) {
            Text("Uncommitted changes", bundle: .module)
            Text(verbatim: Counted.files(files)).font(.caption)
                .foregroundStyle(.secondary)
        }
        // The selection highlight says which rows are picked; a sidebar list would also bold them.
        .fontWeight(.regular)
    }
}

struct CommitRow: View {
    let commit: ReviewCommit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(commit.subject).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 6) {
                Text(commit.shortID).monospaced()
                AgeText(date: commit.date)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .fontWeight(.regular)
        .help(commit.subject)
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
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
        // A sidebar row's content is inset 6 pt more than its selection, so the box reaches out
        // by that much to be as wide as a selected commit, with the text in line with theirs.
        .background(
            RoundedRectangle(cornerRadius: 6).fill(.tint.opacity(0.12)).padding(.horizontal, -6)
        )
        .help(commit.subject)
    }
}

private struct BasePickerPopover: ViewModifier {
    let session: RepoSession
    let review: WorktreeReview

    func body(content: Content) -> some View {
        content.popover(isPresented: Bindable(session).showsBasePicker, arrowEdge: .trailing) {
            BasePicker(session: session, review: review)
        }
    }
}
