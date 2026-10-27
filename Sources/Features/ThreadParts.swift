import DiffModel
import DiffView
import ReviewModel
import SeamCore
import SwiftUI

/// The lines a thread is on, as they were when it was opened. A long quote shows its first lines
/// and a row that expands it; the state goes with the card's conversation when it collapses.
struct QuotedLines: View {
    let anchor: ThreadAnchor
    @State private var showsAll = false

    static let maxRows = 8

    /// How many lines show, and how many the last row says are left out.
    static func visible(_ count: Int, showsAll: Bool) -> (shown: Int, hidden: Int) {
        guard !showsAll, count > maxRows else { return (count, 0) }
        return (maxRows - 1, count - (maxRows - 1))
    }

    var body: some View {
        let (shown, hidden) = Self.visible(anchor.text.count, showsAll: showsAll)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(anchor.text.prefix(shown).enumerated()), id: \.offset) { offset, line in
                row {
                    Text(verbatim: "\(anchor.lines.lowerBound + offset)")
                        .foregroundStyle(.tertiary)
                } text: {
                    Text(verbatim: line.trimmingCharacters(in: .newlines)).lineLimit(1)
                }
            }
            if hidden > 0 {
                Button {
                    showsAll = true
                } label: {
                    row {
                        EmptyView()
                    } text: {
                        Text("\(hidden) more lines", bundle: .module).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
    }

    /// The number column is as wide as the quote's last number, so every row's text lines up.
    private func row(
        @ViewBuilder number: () -> some View, @ViewBuilder text: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ZStack(alignment: .trailing) {
                Text(verbatim: "\(anchor.lines.lowerBound + max(anchor.text.count - 1, 0))")
                    .hidden()
                number()
            }
            .frame(minWidth: 24, alignment: .trailing)
            text()
        }
    }
}

/// A thread's comments: author, age and Markdown body, oldest first, in the card's font.
struct ThreadComments: View {
    let thread: ReviewThread
    var font: Font?
    var authorFont: Font?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: comment.author)
                            .font(authorFont ?? .callout.weight(.semibold))
                        AgeText(date: comment.date).font(font ?? .caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(CommentText.markdown(comment.body)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

enum CommentText {
    /// Inline Markdown, keeping the comment's own line breaks.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
