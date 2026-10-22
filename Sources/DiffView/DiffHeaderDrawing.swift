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
        var disclosure: NSRect
        var checkbox: NSRect
        /// The checkbox and its label, which toggle the mark instead of collapsing the file.
        var viewedFrame: NSRect
    }

    /// Controls are drawn at the text's height so they line up with it; the viewed checkbox
    /// sits at the right edge, in the same place on every file.
    static func layout(
        _ file: ReviewFile, viewed: ViewedMarks.Status, in rect: NSRect, font: NSFont,
        palette: DiffPalette
    ) -> Layout {
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let control = controlSize(font)
        let gap = 12.0
        let disclosure = NSRect(
            x: rect.minX + 10, y: rect.midY - control / 2, width: control, height: control)
        var x = disclosure.maxX + 8
        var pieces: [(line: CTLine, color: RGB, x: Double)] = []
        func add(_ text: String, _ color: RGB, _ textFont: NSFont, at position: Double) -> Double {
            let line = TextLine.make(text, font: textFont)
            pieces.append((line, color, position))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        x += add(title(file), palette.text, bold, at: x) + gap
        // Binary files and pure renames have no lines to count.
        if file.diff.additions + file.diff.deletions > 0 {
            x += add("+\(file.diff.additions)", palette.addedMarker, font, at: x) + gap
            x += add("−\(file.diff.deletions)", palette.removedMarker, font, at: x) + gap
        }

        let label =
            viewed == .changedSinceViewed
            ? String(localized: "Changed since viewed", bundle: .module)
            : String(localized: "Viewed", bundle: .module)
        let labelLine = TextLine.make(label, font: font)
        let labelWidth = CTLineGetTypographicBounds(labelLine, nil, nil, nil)
        let viewedWidth = control + 6 + labelWidth
        // A long path pushes the checkbox along rather than under it.
        let viewedX = max(x, rect.maxX - 14 - viewedWidth)
        let checkbox = NSRect(
            x: viewedX, y: rect.midY - control / 2, width: control, height: control)
        pieces.append((labelLine, palette.gutterText, checkbox.maxX + 6))
        return Layout(
            pieces: pieces, baseline: rect.midY + (bold.ascender + bold.descender) / 2,
            disclosure: disclosure, checkbox: checkbox,
            viewedFrame: NSRect(
                x: viewedX - 6, y: rect.minY, width: viewedWidth + 12, height: rect.height))
    }

    /// About the height of a capital plus its padding, as AppKit sizes a checkbox to its label.
    static func controlSize(_ font: NSFont) -> Double {
        (font.capHeight + 5).rounded()
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
        let layout = layout(file, viewed: viewed, in: rect, font: font, palette: palette)
        drawDisclosure(in: layout.disclosure, collapsed: collapsed, palette: palette, context)
        drawCheckbox(in: layout.checkbox, viewed, palette: palette, context)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for piece in layout.pieces {
            context.setFillColor(piece.color.nsColor.cgColor)
            context.textPosition = CGPoint(x: piece.x, y: layout.baseline)
            CTLineDraw(piece.line, context)
        }
    }

    private static func drawDisclosure(
        in rect: NSRect, collapsed: Bool, palette: DiffPalette, _ context: CGContext
    ) {
        let inset = rect.insetBy(dx: rect.width * 0.28, dy: rect.height * 0.28)
        context.saveGState()
        context.setStrokeColor(palette.gutterText.nsColor.cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if collapsed {
            context.move(to: CGPoint(x: inset.minX + inset.width * 0.25, y: inset.minY))
            context.addLine(to: CGPoint(x: inset.maxX - inset.width * 0.25, y: inset.midY))
            context.addLine(to: CGPoint(x: inset.minX + inset.width * 0.25, y: inset.maxY))
        } else {
            context.move(to: CGPoint(x: inset.minX, y: inset.minY + inset.height * 0.25))
            context.addLine(to: CGPoint(x: inset.midX, y: inset.maxY - inset.height * 0.25))
            context.addLine(to: CGPoint(x: inset.maxX, y: inset.minY + inset.height * 0.25))
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func drawCheckbox(
        in rect: NSRect, _ status: ViewedMarks.Status, palette: DiffPalette, _ context: CGContext
    ) {
        let box = CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3.5, cornerHeight: 3.5,
            transform: nil)
        context.saveGState()
        let fill: NSColor? =
            switch status {
            case .unviewed: nil
            case .viewed: .controlAccentColor
            case .changedSinceViewed: .systemOrange
            }
        context.addPath(box)
        if let fill {
            context.setFillColor(fill.cgColor)
            context.fillPath()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            let mark = rect.insetBy(dx: rect.width * 0.24, dy: rect.height * 0.24)
            if status == .viewed {
                context.move(to: CGPoint(x: mark.minX, y: mark.midY))
                context.addLine(
                    to: CGPoint(x: mark.minX + mark.width * 0.38, y: mark.maxY - mark.height * 0.1))
                context.addLine(to: CGPoint(x: mark.maxX, y: mark.minY + mark.height * 0.1))
            } else {
                context.move(to: CGPoint(x: mark.minX, y: mark.midY))
                context.addLine(to: CGPoint(x: mark.maxX, y: mark.midY))
            }
            context.strokePath()
        } else {
            context.setFillColor(palette.background.nsColor.cgColor)
            context.fillPath()
            context.addPath(box)
            context.setStrokeColor(palette.gutterText.nsColor.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            context.strokePath()
        }
        context.restoreGState()
    }
}

/// The header of the file at the top of the view, pinned while its rows scroll beneath it.
@MainActor
final class DiffStickyHeaderView: NSView {
    var file: ReviewFile? {
        didSet { if file != oldValue { needsDisplay = true } }
    }
    var collapsed = false {
        didSet { if collapsed != oldValue { needsDisplay = true } }
    }
    var viewed = ViewedMarks.Status.unviewed {
        didSet { if viewed != oldValue { needsDisplay = true } }
    }
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) {
        didSet { if font != oldValue { needsDisplay = true } }
    }
    var increaseContrast = false {
        didSet { needsDisplay = true }
    }
    /// Called with true when the click was on the viewed checkbox.
    var onClick: ((_ onViewed: Bool) -> Void)?
    var menuForFile: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? { menuForFile?() }

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
            file, viewed: viewed, in: bounds, font: font, palette: palette)
        onClick?(layout.viewedFrame.contains(point))
    }
}
