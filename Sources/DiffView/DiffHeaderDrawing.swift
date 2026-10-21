import AppKit
import CoreText
import SeamCore

/// File header drawing, shared by the header rows and the sticky header above them.
@MainActor
enum DiffHeaderDrawing {
    static func title(_ file: ReviewFile) -> String {
        let path =
            if let old = file.diff.oldPath, let new = file.diff.newPath, old != new {
                "\(old) → \(new)"
            } else {
                file.diff.path
            }
        var tags: [String] = []
        if file.isUntracked { tags.append(String(localized: "untracked", bundle: .module)) }
        if file.isGenerated { tags.append(String(localized: "generated", bundle: .module)) }
        let suffix = tags.isEmpty ? "" : "  (" + tags.joined(separator: ", ") + ")"
        return "\(file.diff.status.letter)  \(path)\(suffix)"
    }

    /// Where each piece of a header goes; drawing and hit testing share it.
    struct Layout {
        var pieces: [(line: CTLine, color: RGB, x: Double)]
        var baseline: Double
        /// The viewed checkbox, which toggles the mark instead of collapsing the file.
        var viewedFrame: NSRect
    }

    static func layout(
        _ file: ReviewFile, collapsed: Bool, viewed: ViewedMarks.Status, in rect: NSRect,
        font: NSFont, palette: DiffPalette
    ) -> Layout {
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let viewedLabel =
            switch viewed {
            case .unviewed: String(localized: "☐ Viewed", bundle: .module)
            case .viewed: String(localized: "☑ Viewed", bundle: .module)
            case .changedSinceViewed: String(localized: "◐ Changed since viewed", bundle: .module)
            }
        var x = rect.minX + 10
        var pieces: [(line: CTLine, color: RGB, x: Double)] = []
        var viewedFrame = NSRect.zero
        for (text, color, textFont) in [
            (collapsed ? "▸" : "▾", palette.gutterText, font),
            (title(file), palette.text, bold),
            ("+\(file.diff.additions)", palette.addedMarker, font),
            ("−\(file.diff.deletions)", palette.removedMarker, font),
            (
                viewedLabel,
                viewed == .changedSinceViewed ? palette.removedMarker : palette.gutterText, font
            ),
        ] {
            let line = TextLine.make(text, font: textFont)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            if text == viewedLabel {
                x += 12
                viewedFrame = NSRect(x: x - 6, y: rect.minY, width: width + 12, height: rect.height)
            }
            pieces.append((line, color, x))
            x += width + 12
        }
        return Layout(
            pieces: pieces, baseline: rect.midY + (bold.ascender + bold.descender) / 2,
            viewedFrame: viewedFrame)
    }

    static func draw(
        _ file: ReviewFile, collapsed: Bool, viewed: ViewedMarks.Status, in rect: NSRect,
        font: NSFont, palette: DiffPalette, context: CGContext
    ) {
        context.setFillColor(palette.headerBackground.nsColor.cgColor)
        context.fill(rect)
        context.setFillColor(palette.separator.nsColor.cgColor)
        context.fill(NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        context.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
        let layout = layout(
            file, collapsed: collapsed, viewed: viewed, in: rect, font: font, palette: palette)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for piece in layout.pieces {
            context.setFillColor(piece.color.nsColor.cgColor)
            context.textPosition = CGPoint(x: piece.x, y: layout.baseline)
            CTLineDraw(piece.line, context)
        }
    }
}

/// The header of the file at the top of the view, pinned while its rows scroll beneath it.
@MainActor
final class DiffStickyHeaderView: NSView {
    var file: ReviewFile?
    var collapsed = false
    var viewed = ViewedMarks.Status.unviewed
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var increaseContrast = false
    /// Called with true when the click was on the viewed checkbox.
    var onClick: ((_ onViewed: Bool) -> Void)?

    override var isFlipped: Bool { true }

    private var palette: DiffPalette {
        DiffPalette.current(for: effectiveAppearance, increaseContrast: increaseContrast)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let file, let context = NSGraphicsContext.current?.cgContext else { return }
        DiffHeaderDrawing.draw(
            file, collapsed: collapsed, viewed: viewed, in: bounds, font: font, palette: palette,
            context: context)
    }

    override func mouseDown(with event: NSEvent) {
        guard let file else { return }
        let point = convert(event.locationInWindow, from: nil)
        let layout = DiffHeaderDrawing.layout(
            file, collapsed: collapsed, viewed: viewed, in: bounds, font: font, palette: palette)
        onClick?(layout.viewedFrame.contains(point))
    }

    override func isAccessibilityElement() -> Bool { file != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { file.map(DiffHeaderDrawing.title) }
    override func accessibilityPerformPress() -> Bool {
        onClick?(false)
        return true
    }
}
