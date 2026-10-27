import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// "3 awaiting you" in the header.
struct InboxSummary: View {
    let session: RepoSession

    var body: some View {
        let count = session.inbox.count
        if count > 0 {
            Text(String(localized: "\(count) awaiting you", bundle: .module))
                .foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The Inbox navigator (SPEC §7.3.2): across every worktree, the threads whose latest word is
/// an agent's and the pull requests whose checks failed, by worktree, newest first. Picking a
/// thread opens it where it is, in its worktree.
struct InboxList: View {
    let session: RepoSession

    var body: some View {
        let groups = session.inboxGroups
        List(selection: selection) {
            ForEach(groups, id: \.worktree) { group in
                Section {
                    ForEach(group.items) { item in
                        InboxRow(session: session, item: item)
                            .tag(item.id)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    Text(verbatim: name(of: group.worktree)).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    String(localized: "Nothing awaits you", bundle: .module),
                    systemImage: "tray",
                    description: Text(
                        "Agents' answers and questions, and failed checks, show here from every worktree.",
                        bundle: .module))
            }
        }
    }

    private func name(of worktree: String) -> String {
        session.reviews.first { $0.id == worktree }?.worktree.name ?? worktree
    }

    private var selection: Binding<String?> {
        Binding(
            get: { session.selectedThreadID },
            set: { id in
                guard let item = session.inbox.first(where: { $0.id == id }) else { return }
                Task { await session.open(item) }
            })
    }
}

private struct InboxRow: View {
    let session: RepoSession
    let item: InboxItem

    var body: some View {
        switch item.kind {
        case .thread(let thread):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "\(thread.anchor.path):\(thread.anchor.lines.lowerBound)")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    AgeText(date: item.date)
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(snippet(thread)).lineLimit(2)
            }
            .padding(.vertical, 2)
        case .failedChecks(let pullRequest):
            HStack(spacing: 6) {
                Text(PullRequestText.checksFailed(pullRequest.number))
                Spacer(minLength: 4)
                Button(String(localized: "Open Failed Check", bundle: .module)) {
                    guard let review = session.reviews.first(where: { $0.id == item.worktree })
                    else { return }
                    session.openFailedCheck(of: review)
                }
                .buttonStyle(.link)
            }
            .padding(.vertical, 2)
        }
    }

    private func snippet(_ thread: ReviewThread) -> AttributedString {
        guard let latest = thread.comments.last else { return AttributedString() }
        var author = AttributedString("\(latest.author)  ")
        author.inlinePresentationIntent = .stronglyEmphasized
        return author + CommentText.markdown(latest.body)
    }
}
