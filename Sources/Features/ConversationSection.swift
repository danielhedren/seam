import DiffView
import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// The pull request's conversation in the thread panel (SPEC §7.9): its comments and its
/// reviews' verdicts, read-only, the latest few first shown.
struct ConversationSection: View {
    let session: RepoSession
    let review: WorktreeReview
    let conversation: PullRequestConversation
    @State private var showsAll = false

    static let shown = 3

    var body: some View {
        let items = conversation.items
        let hidden = showsAll ? 0 : max(items.count - Self.shown, 0)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Octicon.mark.image.resizable().frame(width: 12, height: 12)
                    .foregroundStyle(Color(nsColor: ThreadColor.gitHubAccent))
                Text(
                    String(
                        localized: "Conversation on #\(String(conversation.pullRequest))",
                        bundle: .module))
                Spacer(minLength: 4)
                Button(String(localized: "Open on GitHub", bundle: .module)) {
                    session.openPullRequest(of: review)
                }
                .buttonStyle(.link)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if hidden > 0 {
                Button(String(localized: "\(hidden) earlier", bundle: .module)) {
                    showsAll = true
                }
                .buttonStyle(.link).font(.caption)
            }
            ForEach(items.suffix(items.count - hidden), id: \.key) { item in
                row(item)
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
    }

    private func row(_ item: GitHubConversationItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: item.author).font(.callout.weight(.semibold))
                if let verdict = PullRequestText.verdict(item.kind) {
                    Text(verbatim: verdict).font(.caption)
                        .padding(.horizontal, 5)
                        .background(verdictColor(item.kind).opacity(0.18), in: Capsule())
                }
                AgeText(date: item.created).font(.caption).foregroundStyle(.secondary)
            }
            if !item.body.isEmpty {
                Text(CommentText.markdown(item.body)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contextMenu {
            Button(String(localized: "Open on GitHub", bundle: .module)) {
                session.openOnGitHub(item)
            }
        }
    }

    private func verdictColor(_ kind: GitHubConversationItem.Kind) -> Color {
        switch kind {
        case .approved: .green
        case .changesRequested: .red
        case .comment, .commented, .dismissed: .secondary
        }
    }
}

extension GitHubConversationItem {
    /// A comment and a review can share a database id.
    fileprivate var key: String { "\(kind == .comment ? "c" : "r")\(id)" }
}
