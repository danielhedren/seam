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
        _ file: ReviewFile, viewed: ViewedMarks.Status, sinceViewed: Bool = false, in rect: NSRect,
        font: NSFont, palette: DiffPalette
    ) -> Layout {
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let control = controlSize(font)
        let gap = 12.0
        let disclosure = NSRect(
            x: rect.minX + 10, y: rect.midY - control / 2, width: control, height: control)
        var x = disclosure.maxX + 8
        var pieces: [(line: CTLine, color: RGB, x: Double)] = []
        func width(_ line: CTLine) -> Double { CTLineGetTypographicBounds(line, nil, nil, nil) }
        // Binary files and pure renames have no lines to count.
        var counts =
            file.diff.additions + file.diff.deletions > 0
            ? [
                (TextLine.make("+\(file.diff.additions)", font: font), palette.addedMarker),
                (TextLine.make("−\(file.diff.deletions)", font: font), palette.removedMarker),
            ] : []
        // Says the counts and lines are the change since viewed, not the change on the branch.
        if sinceViewed {
            counts.append(
                (
                    TextLine.make(String(localized: "since viewed", bundle: .module), font: font),
                    palette.gutterText
                ))
        }
        let label =
            viewed == .changedSinceViewed
            ? String(localized: "Changed since viewed", bundle: .module)
            : String(localized: "Viewed", bundle: .module)
        let labelLine = TextLine.make(label, font: font)
        let viewedWidth = control + 6 + width(labelLine)

        // A long path gives way in the middle, as Finder's does, so the counts and the
        // checkbox stay in a narrow pane.
        let countsWidth = counts.reduce(0) { $0 + width($1.0) + gap }
        let room = rect.maxX - 14 - viewedWidth - gap - countsWidth - x
        var titleLine = TextLine.make(title(file), font: bold)
        if width(titleLine) > room,
            let truncated = CTLineCreateTruncatedLine(
                titleLine, max(room, 0), .middle, TextLine.make("…", font: bold))
        {
            titleLine = truncated
        }
        pieces.append((titleLine, palette.text, x))
        x += width(titleLine) + gap
        for (line, color) in counts {
            pieces.append((line, color, x))
            x += width(line) + gap
        }
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
        _ file: ReviewFile, collapsed: Bool, viewed: ViewedMarks.Status, sinceViewed: Bool = false,
        in rect: NSRect, font: NSFont, palette: DiffPalette, context: CGContext,
        topBorder: Bool = true
    ) {
        context.setFillColor(palette.headerBackground.nsColor.cgColor)
        context.fill(rect)
        context.setFillColor(palette.separator.nsColor.cgColor)
        context.fill(NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        // A header right below another, a collapsed file's, shares that one's bottom border.
        if topBorder {
            context.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))
        }
        let layout = layout(
            file, viewed: viewed, sinceViewed: sinceViewed, in: rect, font: font, palette: palette)
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
        didSet {
            guard file != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var collapsed = false {
        didSet { if collapsed != oldValue { needsDisplay = true } }
    }
    var viewed = ViewedMarks.Status.unviewed {
        didSet { if viewed != oldValue { needsDisplay = true } }
    }
    var sinceViewed = false {
        didSet { if sinceViewed != oldValue { needsDisplay = true } }
    }
    var viewedHelp: ((ViewedMarks.Status) -> String)?
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

    /// A click anywhere collapses the file, or toggles the viewed mark.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
        removeAllToolTips()
        guard let file, viewedHelp != nil else { return }
        let layout = DiffHeaderDrawing.layout(
            file, viewed: viewed, sinceViewed: sinceViewed, in: bounds, font: font,
            palette: palette)
        addToolTip(layout.viewedFrame, owner: self, userData: nil)
    }

    private var palette: DiffPalette {
        DiffPalette.current(for: effectiveAppearance, increaseContrast: increaseContrast)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let file, let context = NSGraphicsContext.current?.cgContext else { return }
        DiffHeaderDrawing.draw(
            file, collapsed: collapsed, viewed: viewed, sinceViewed: sinceViewed, in: bounds,
            font: font, palette: palette, context: context)
    }

    override func mouseDown(with event: NSEvent) {
        guard let file else { return }
        let point = convert(event.locationInWindow, from: nil)
        let layout = DiffHeaderDrawing.layout(
            file, viewed: viewed, sinceViewed: sinceViewed, in: bounds, font: font,
            palette: palette)
        onClick?(layout.viewedFrame.contains(point))
    }
}

extension DiffStickyHeaderView: NSViewToolTipOwner {
    nonisolated func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated { viewedHelp?(viewed) ?? "" }
    }
}
