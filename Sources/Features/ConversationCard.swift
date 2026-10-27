import AppKit
import DiffView
import GitKit
import ReviewModel
import SeamCore
import SwiftUI

/// The pull request's conversation, open above the first file (SPEC §7.9): its comments and its
/// reviews' verdicts, read-only, laid out as a thread's card is.
struct ConversationCard: View {
    let session: RepoSession
    let review: WorktreeReview
    let conversation: PullRequestConversation

    var body: some View {
        let font = session.settings.font
        let bold = Font(NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask))
        VStack(alignment: .leading, spacing: 10) {
            Button {
                session.closeThread()
            } label: {
                HStack(spacing: 6) {
                    Octicon.mark.image.resizable().frame(width: 13, height: 13)
                        .foregroundStyle(Color(nsColor: ThreadColor.gitHubAccent))
                    Text(verbatim: review.marker(for: WorktreeReview.conversationID)?.title ?? "")
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain).pointerStyle(.link)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(conversation.items, id: \.key) { item in
                    row(item, bold: bold)
                }
            }
            HStack(spacing: 24) {
                Spacer()
                Button(String(localized: "Open on GitHub", bundle: .module)) {
                    session.openPullRequest(of: review)
                }
                Button {
                    session.closeThread()
                } label: {
                    Text(verbatim: "⎋ \(String(localized: "Close", bundle: .module))")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .pointerStyle(.link)
        }
        .font(Font(font))
        .onExitCommand { session.closeThread() }
    }

    private func row(_ item: GitHubConversationItem, bold: Font) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: item.author).font(bold)
                if let verdict = PullRequestText.verdict(item.kind) {
                    Text(verbatim: verdict)
                        .padding(.horizontal, 5)
                        .background(verdictColor(item.kind).opacity(0.18), in: Capsule())
                }
                AgeText(date: item.created).foregroundStyle(.secondary)
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
