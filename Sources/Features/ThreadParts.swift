import AppKit
import DiffModel
import DiffView
import GitKit
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

/// What became of an outdated thread's lines (SPEC §7.7): the change from the file it was
/// written on to the file now, around them, as a small diff in the card's font. The lines it
/// was written on carry the threads' amber in their gutter.
struct SinceChange: View {
    let since: ThreadSince
    let anchor: ThreadAnchor
    let font: NSFont

    var body: some View {
        let lines = since.hunks.flatMap { hunk in [nil] + hunk.lines.map(Optional.some) }
            .dropFirst()
        let width = String(lines.compactMap { $0?.oldNumber ?? $0?.newNumber }.max() ?? 0).count
        VStack(alignment: .leading, spacing: 4) {
            Text("Changed since this comment", bundle: .module).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let line {
                        row(line, width: width)
                    } else {
                        Text(verbatim: "⋯").foregroundStyle(.tertiary).padding(.leading, 9)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
        }
        .font(Font(font))
    }

    private func row(_ line: DiffLine, width: Int) -> some View {
        let isAnchor = line.oldNumber.map(anchor.lines.contains) ?? false
        let sign =
            switch line.kind {
            case .added: "+"
            case .removed: "−"
            case .context: " "
            }
        return HStack(spacing: 6) {
            Text(verbatim: number(line.oldNumber, width) + " " + number(line.newNumber, width))
                .foregroundStyle(.tertiary)
            Text(verbatim: "\(sign) \(line.text.trimmingCharacters(in: .newlines))")
                .lineLimit(1)
        }
        .padding(.leading, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(line.kind))
        .overlay(alignment: .leading) {
            if isAnchor {
                Color(nsColor: ThreadColor.accent(.seam, note: false)).frame(width: 3)
            }
        }
    }

    private func number(_ value: Int?, _ width: Int) -> String {
        let text = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(width - text.count, 0)) + text
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        case .context: .clear
        }
    }
}
