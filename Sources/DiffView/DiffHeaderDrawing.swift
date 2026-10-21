import AppKit
import CoreText
import SeamCore

/// File header drawing, shared by the header rows and the sticky header above them.
@MainActor
enum DiffHeaderDrawing {
    static func line(_ text: String, font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
    }

    /// Unhighlighted runs take the context's fill colour; spans carry their own.
    static func line(
        _ text: String, font: NSFont, syntax: [SyntaxSpan], palette: DiffPalette
    ) -> CTLine {
        let string = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let length = text.count
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(length + 1)
        var offset = 0
        for character in text {
            utf16Offsets.append(offset)
            offset += character.utf16.count
        }
        utf16Offsets.append(offset)
        for span in syntax {
            guard let color = palette.color(for: span.token), span.range.lowerBound < length
            else { continue }
            let lower = utf16Offsets[span.range.lowerBound]
            let upper = utf16Offsets[min(span.range.upperBound, length)]
            let range = NSRange(location: lower, length: upper - lower)
            string.removeAttribute(
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String),
                range: range)
            string.addAttribute(
                NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                value: color.nsColor.cgColor, range: range)
        }
        return CTLineCreateWithAttributedString(string)
    }

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

    static func draw(
        _ file: ReviewFile, collapsed: Bool, in rect: NSRect, font: NSFont, palette: DiffPalette,
        context: CGContext
    ) {
        context.setFillColor(palette.headerBackground.nsColor.cgColor)
        context.fill(rect)
        context.setFillColor(palette.separator.nsColor.cgColor)
        context.fill(NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1))
        context.fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))

        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let baseline = rect.midY + (bold.ascender + bold.descender) / 2
        var x = rect.minX + 10
        for (text, color, textFont) in [
            (collapsed ? "▸" : "▾", palette.gutterText, font),
            (title(file), palette.text, bold),
            ("+\(file.diff.additions)", palette.addedMarker, font),
            ("−\(file.diff.deletions)", palette.removedMarker, font),
        ] {
            let line = Self.line(text, font: textFont)
            context.setFillColor(color.nsColor.cgColor)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line, context)
            x += CTLineGetTypographicBounds(line, nil, nil, nil) + 12
        }
    }
}

/// The header of the file at the top of the view, pinned while its rows scroll beneath it.
@MainActor
final class DiffStickyHeaderView: NSView {
    var file: ReviewFile?
    var collapsed = false
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var onClick: (() -> Void)?
    var increaseContrast = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let file, let context = NSGraphicsContext.current?.cgContext else { return }
        DiffHeaderDrawing.draw(
            file, collapsed: collapsed, in: bounds, font: font,
            palette: DiffPalette.current(
                for: effectiveAppearance, increaseContrast: increaseContrast), context: context)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func isAccessibilityElement() -> Bool { file != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { file.map(DiffHeaderDrawing.title) }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
