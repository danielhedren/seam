import AppKit
import DiffModel

/// A closed thread: the open card collapsed to its title and the latest comment, in the same
/// frame, font and margins (`DiffCanvasView+Card.swift`, Features' `ThreadCardView`), so
/// opening it only shows more. Its title opens it, as the open card's title closes it.
extension DiffCanvasView {
    private static let markSize = 13.0
    private static let markSpacing = 6.0

    /// The card view's margin plus its own horizontal padding.
    private func collapsedInner(row: Int) -> NSRect {
        draftFrame(row: row).insetBy(dx: DiffCardMetrics.margin + 7, dy: DiffCardMetrics.margin)
    }

    private func line(_ text: String, _ font: NSFont, _ color: RGB) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: color.nsColor]))
    }

    private func width(_ line: CTLine) -> Double {
        CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// The title's mark (GitHub's) and text, shortened in the middle to fit, as SwiftUI does.
    private func collapsedTitle(_ marker: ThreadMarker, row: Int, palette: DiffPalette)
        -> (mark: NSRect?, text: CTLine, x: Double, frame: NSRect)
    {
        let inner = collapsedInner(row: row)
        let textHeight = layout.metrics.lineHeight - 4
        var x = inner.minX
        var mark: NSRect?
        if marker.source == .gitHub, gitHubMark != nil {
            mark = NSRect(
                x: x, y: (inner.minY + (textHeight - Self.markSize) / 2).rounded(),
                width: Self.markSize, height: Self.markSize)
            x += Self.markSize + Self.markSpacing
        }
        let full = line(marker.title, font, palette.gutterText)
        let room = max(inner.maxX - x, 1)
        let text =
            width(full) <= room
            ? full
            : CTLineCreateTruncatedLine(full, room, .middle, line("…", font, palette.gutterText))
                ?? full
        let frame = NSRect(
            x: inner.minX, y: inner.minY, width: x + width(text) - inner.minX, height: textHeight)
        return (mark, text, x, frame)
    }

    /// Where a click opens the collapsed card, and the pointer is a hand.
    func collapsedTitleFrame(row: Int) -> NSRect? {
        guard case .thread(_, let marker) = layout.rows[row] else { return nil }
        return collapsedTitle(marker, row: row, palette: .light).frame
    }

    func drawCollapsedCard(
        _ marker: ThreadMarker, row: Int, palette: DiffPalette, context: CGContext
    ) {
        drawCardFrame(
            row: row, source: marker.source, isNote: marker.isNote, palette: palette,
            context: context)
        let inner = collapsedInner(row: row)
        let title = collapsedTitle(marker, row: row, palette: palette)
        if let rect = title.mark, let image = gitHubMark {
            let tinted = NSImage(size: rect.size, flipped: true) { bounds in
                image.draw(in: bounds)
                ThreadColor.gitHubAccent.set()
                bounds.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: nil)
        }
        context.textPosition = CGPoint(x: title.x, y: inner.minY + font.ascender)
        CTLineDraw(title.text, context)

        let body = marker.isResolved ? palette.gutterText : palette.text
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let author = line(marker.latestAuthor + " ", bold, body)
        let latest = line(marker.latest, font, body)
        let room = max(inner.width - width(author), 1)
        let shown =
            width(latest) <= room
            ? latest
            : CTLineCreateTruncatedLine(latest, room, .end, line("…", font, body)) ?? latest
        let y = inner.minY + layout.metrics.lineHeight - 4 + 6 + font.ascender
        context.textPosition = CGPoint(x: inner.minX, y: y)
        CTLineDraw(author, context)
        context.textPosition = CGPoint(x: inner.minX + width(author), y: y)
        CTLineDraw(shown, context)
    }
}
