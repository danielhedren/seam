import AppKit
import CoreText
import GitKit
import SeamCore

/// The diff document view: draws only the visible rows with Core Text (SPEC §8.5). Both split
/// columns live in this one view, so they scroll together by construction.
@MainActor
final class DiffCanvasView: NSView {
    private(set) var layout: DiffLayout
    private(set) var review = ReviewDiff(scope: .all, files: [])
    private(set) var mode = DiffLayoutMode.unified
    private(set) var collapsed: Set<String> = []
    var isStale = false {
        didSet { if isStale != oldValue { needsDisplay = true } }
    }
    var selection: DiffSelection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }
    var onToggleCollapse: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    let font: NSFont
    private var geometry = Geometry()
    private var lineCache: [LineKey: CTLine] = [:]
    private var dragStart: TextPosition?

    init(font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)) {
        self.font = font
        layout = DiffLayout(rows: [], metrics: Self.metrics(for: font))
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    static func metrics(for font: NSFont) -> DiffLayout.Metrics {
        let line = ceil(font.ascender - font.descender + font.leading) + 4
        let width = font.advancement(forGlyph: font.glyph(withName: "M")).width
        return DiffLayout.Metrics(
            lineHeight: line, fileHeaderHeight: ceil(line * 1.75),
            characterWidth: width > 0 ? width : font.pointSize * 0.6)
    }

    func show(_ review: ReviewDiff, mode: DiffLayoutMode, collapsed: Set<String>) {
        self.review = review
        self.mode = mode
        self.collapsed = collapsed
        layout = DiffLayout(
            rows: DiffRowBuilder.rows(for: review, mode: mode, collapsed: collapsed),
            metrics: layout.metrics)
        lineCache.removeAll(keepingCapacity: true)
        selection = nil
        geometry = Geometry(layout: layout, mode: mode, visibleWidth: geometry.visibleWidth)
        resize()
        needsDisplay = true
    }

    func setVisibleWidth(_ width: Double) {
        guard width != geometry.visibleWidth else { return }
        geometry = Geometry(layout: layout, mode: mode, visibleWidth: width)
        resize()
    }

    private func resize() {
        let size = NSSize(width: geometry.documentWidth, height: max(layout.totalHeight, 1))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
    }

    var paths: [String] { review.files.map(\.diff.path) }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let palette = DiffPalette.current(for: effectiveAppearance)
        context.setFillColor(palette.background.nsColor.cgColor)
        context.fill(dirtyRect)
        if isStale { context.setAlpha(0.5) }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in layout.rows(in: dirtyRect.minY, dirtyRect.maxY) {
            let rect = NSRect(
                x: 0, y: layout.top(of: index), width: bounds.width,
                height: layout.height(of: index))
            draw(row: index, in: rect, palette: palette, context: context)
        }
    }

    private func draw(row index: Int, in rect: NSRect, palette: DiffPalette, context: CGContext) {
        switch layout.rows[index] {
        case .fileHeader(let file):
            DiffHeaderDrawing.draw(
                review.files[file], collapsed: collapsed.contains(review.files[file].diff.path),
                in: rect, font: font, palette: palette, context: context)
        case .hunkHeader(_, _, let text):
            fill(rect, palette.hunkBackground, context)
            drawText(
                text, key: LineKey(row: index, side: .unified), x: geometry.unifiedTextX,
                rowTop: rect.minY, color: palette.hunkText, context: context)
        case .notice(_, let text):
            drawText(
                text, key: LineKey(row: index, side: .unified), x: geometry.unifiedTextX,
                rowTop: rect.minY, color: palette.gutterText, context: context)
        case .line(_, let old, let new, let kind, let text, let noNewline):
            let column = Column(
                x: 0, width: rect.width, numbers: [old, new], textX: geometry.unifiedTextX)
            drawSide(
                kind: kind, text: text, noNewline: noNewline, column: column, row: index,
                side: .unified, rowTop: rect.minY, palette: palette, context: context)
        case .split(_, let left, let right):
            for (line, side) in [(left, DiffSide.left), (right, DiffSide.right)] {
                let x = side == .left ? 0 : geometry.columnWidth
                let column = Column(
                    x: x, width: geometry.columnWidth, numbers: [line?.number],
                    textX: x + geometry.splitTextOffset)
                let bounds = NSRect(x: x, y: rect.minY, width: column.width, height: rect.height)
                guard let line else {
                    fill(bounds, palette.emptySide, context)
                    continue
                }
                // Long lines are clipped at the column edge rather than spilling into the other.
                context.saveGState()
                context.clip(to: bounds)
                drawSide(
                    kind: line.kind, text: line.text, noNewline: line.noNewlineAtEnd,
                    column: column, row: index, side: side, rowTop: rect.minY, palette: palette,
                    context: context)
                context.restoreGState()
            }
            context.setFillColor(palette.separator.nsColor.cgColor)
            context.fill(
                NSRect(x: geometry.columnWidth, y: rect.minY, width: 1, height: rect.height))
        }
    }

    private struct Column {
        var x: Double
        var width: Double
        var numbers: [Int?]
        var textX: Double
    }

    private func drawSide(
        kind: DiffLine.Kind, text: String, noNewline: Bool, column: Column, row: Int,
        side: DiffSide, rowTop: Double, palette: DiffPalette, context: CGContext
    ) {
        let height = layout.metrics.lineHeight
        let gutterWidth = geometry.numberWidth * Double(column.numbers.count)
        let (background, gutter, marker, symbol): (RGB?, RGB?, RGB, String) =
            switch kind {
            case .added: (palette.addedBackground, palette.addedGutter, palette.addedMarker, "+")
            case .removed:
                (palette.removedBackground, palette.removedGutter, palette.removedMarker, "−")
            case .context: (nil, nil, palette.gutterText, " ")
            }
        if let background {
            fill(
                NSRect(x: column.x, y: rowTop, width: column.width, height: height), background,
                context)
        }
        if let gutter {
            fill(
                NSRect(x: column.x, y: rowTop, width: gutterWidth, height: height), gutter, context)
        }
        for (offset, number) in column.numbers.enumerated() {
            guard let number else { continue }
            let label = String(number)
            let right = column.x + geometry.numberWidth * Double(offset + 1) - geometry.padding
            drawText(
                label, key: nil, x: right - Double(label.count) * layout.metrics.characterWidth,
                rowTop: rowTop, color: palette.gutterText, context: context)
        }
        drawText(
            symbol, key: nil, x: column.x + gutterWidth + geometry.padding / 2, rowTop: rowTop,
            color: marker, context: context)
        if let selection, selection.side == side,
            let range = selection.columns(inRow: row, length: text.count + 1), !range.isEmpty
        {
            let width = layout.metrics.characterWidth
            let highlight = NSRect(
                x: column.textX + Double(range.lowerBound) * width, y: rowTop,
                width: Double(range.count) * width, height: height)
            let color =
                window?.firstResponder === self
                ? NSColor.selectedTextBackgroundColor
                : NSColor.unemphasizedSelectedTextBackgroundColor
            context.setFillColor(color.cgColor)
            context.fill(highlight)
        }
        drawText(
            text, key: LineKey(row: row, side: side), x: column.textX, rowTop: rowTop,
            color: palette.text, context: context)
        if noNewline {
            let x = column.textX + Double(text.count + 1) * layout.metrics.characterWidth
            drawText(
                "⊘ no newline at end of file", key: nil, x: x, rowTop: rowTop,
                color: palette.gutterText, context: context)
        }
    }

    private func fill(_ rect: NSRect, _ color: RGB, _ context: CGContext) {
        context.setFillColor(color.nsColor.cgColor)
        context.fill(rect)
    }

    private func drawText(
        _ text: String, key: LineKey?, x: Double, rowTop: Double, color: RGB, context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let line: CTLine
        if let key, let cached = lineCache[key] {
            line = cached
        } else {
            line = DiffHeaderDrawing.line(text, font: font)
            if let key {
                if lineCache.count > 20_000 { lineCache.removeAll(keepingCapacity: true) }
                lineCache[key] = line
            }
        }
        context.setFillColor(color.nsColor.cgColor)
        context.textPosition = CGPoint(x: x, y: rowTop + 2 + font.ascender)
        CTLineDraw(line, context)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Selection and copy

    func position(at point: NSPoint) -> (DiffSide, TextPosition)? {
        guard let row = layout.row(at: point.y) else { return nil }
        let side: DiffSide =
            mode == .unified ? .unified : point.x < geometry.columnWidth ? .left : .right
        let textX =
            switch side {
            case .unified: geometry.unifiedTextX
            case .left: geometry.splitTextOffset
            case .right: geometry.columnWidth + geometry.splitTextOffset
            }
        let length = layout.text(of: row, side: side)?.count ?? 0
        let column = Int(((point.x - textX) / layout.metrics.characterWidth).rounded())
        return (side, TextPosition(row: row, column: min(max(column, 0), length)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let (side, position) = self.position(at: point) else { return }
        if case .fileHeader(let file) = layout.rows[position.row] {
            onToggleCollapse?(review.files[file].diff.path)
            return
        }
        switch event.clickCount {
        case 2:
            selection = wordSelection(side: side, at: position)
        case 3...:
            let length = layout.text(of: position.row, side: side)?.count ?? 0
            selection = DiffSelection(
                side: side, anchor: TextPosition(row: position.row, column: 0),
                head: TextPosition(row: position.row, column: length + 1))
        default:
            if event.modifierFlags.contains(.shift), let current = selection {
                selection = DiffSelection(
                    side: current.side, anchor: current.anchor, head: position)
            } else {
                selection = DiffSelection(side: side, anchor: position, head: position)
            }
        }
        dragStart = position
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = selection, dragStart != nil else { return }
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let (_, position) = self.position(at: point) else { return }
        selection = DiffSelection(side: current.side, anchor: current.anchor, head: position)
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    private func wordSelection(side: DiffSide, at position: TextPosition) -> DiffSelection {
        let characters = Array(layout.text(of: position.row, side: side) ?? "")
        func isWord(_ index: Int) -> Bool {
            characters.indices.contains(index)
                && (characters[index].isLetter || characters[index].isNumber
                    || characters[index] == "_")
        }
        var start = position.column
        var end = position.column
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        if start == end, end < characters.count { end += 1 }
        return DiffSelection(
            side: side, anchor: TextPosition(row: position.row, column: start),
            head: TextPosition(row: position.row, column: end))
    }

    @objc func copy(_ sender: Any?) {
        guard let selection, !selection.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(layout.text(of: selection), forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard !layout.rows.isEmpty else { return }
        let side: DiffSide = mode == .unified ? .unified : selection?.side ?? .right
        let last = layout.rows.count - 1
        selection = DiffSelection(
            side: side, anchor: TextPosition(row: 0, column: 0),
            head: TextPosition(row: last, column: (layout.text(of: last, side: side)?.count ?? 0)))
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        String(localized: "Diff", bundle: .module)
    }

    override func accessibilityChildren() -> [Any]? {
        layout.rows(in: visibleRect.minY, visibleRect.maxY).map { index in
            let rect = NSRect(
                x: 0, y: layout.top(of: index), width: bounds.width,
                height: layout.height(of: index))
            let frame = window?.convertToScreen(convert(rect, to: nil)) ?? rect
            return NSAccessibilityElement.element(
                withRole: .staticText, frame: frame, label: accessibilityLabel(row: index),
                parent: self)
        }
    }

    private func accessibilityLabel(row index: Int) -> String {
        func describe(_ kind: DiffLine.Kind, _ number: Int?, side: String, _ text: String) -> String
        {
            let kindName =
                switch kind {
                case .added: String(localized: "added", bundle: .module)
                case .removed: String(localized: "removed", bundle: .module)
                case .context: String(localized: "unchanged", bundle: .module)
                }
            let line = number.map { String(localized: "\(side) line \($0)", bundle: .module) } ?? ""
            return "\(kindName), \(line): \(text)"
        }
        switch layout.rows[index] {
        case .fileHeader(let file): return review.files[file].diff.path
        case .hunkHeader(_, _, let text), .notice(_, let text): return text
        case .line(_, let old, let new, let kind, let text, _):
            return describe(kind, new ?? old, side: new == nil ? "old" : "new", text)
        case .split(_, let left, let right):
            return [
                left.map { describe($0.kind, $0.number, side: "old", $0.text) },
                right.map { describe($0.kind, $0.number, side: "new", $0.text) },
            ].compactMap(\.self).joined(separator: "; ")
        }
    }
}

extension DiffCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selection.map { !$0.isEmpty } ?? false }
        return true
    }
}

private struct LineKey: Hashable {
    var row: Int
    var side: DiffSide
}

/// Column positions for the current layout and width.
struct Geometry {
    var visibleWidth = 0.0
    var padding = 8.0
    var numberWidth = 0.0
    var unifiedTextX = 0.0
    var splitTextOffset = 0.0
    var columnWidth = 0.0
    var documentWidth = 0.0

    init() {}

    init(layout: DiffLayout, mode: DiffLayoutMode, visibleWidth: Double) {
        self.visibleWidth = visibleWidth
        let character = layout.metrics.characterWidth
        let digits = max(3, String(Self.largestNumber(layout.rows)).count)
        numberWidth = Double(digits) * character + padding * 2
        let marker = character + padding
        unifiedTextX = numberWidth * 2 + marker
        splitTextOffset = numberWidth + marker
        let text = Double(layout.maxColumns + 2) * character + padding
        switch mode {
        case .unified:
            columnWidth = max(visibleWidth, unifiedTextX + text)
            documentWidth = columnWidth
        // Split columns stay at half the view so both sides are always visible; horizontal
        // scrolling would move the right side out of view.
        case .split:
            columnWidth = max(visibleWidth / 2, splitTextOffset + character * 20)
            documentWidth = columnWidth * 2
        }
    }

    private static func largestNumber(_ rows: [DiffRow]) -> Int {
        rows.reduce(0) { largest, row in
            switch row {
            case .line(_, let old, let new, _, _, _): max(largest, old ?? 0, new ?? 0)
            case .split(_, let left, let right):
                max(largest, left?.number ?? 0, right?.number ?? 0)
            default: largest
            }
        }
    }
}
