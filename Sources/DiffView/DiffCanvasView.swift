import AppKit
import CoreText
import GitKit
import SeamCore
import os

/// The diff document view: draws only the visible rows with Core Text (SPEC §8.5). Both split
/// columns live in this one view, so they scroll together by construction.
@MainActor
final class DiffCanvasView: NSView {
    private(set) var layout: DiffLayout
    private(set) var review = ReviewDiff(scope: .all, files: [])
    private(set) var mode = DiffLayoutMode.unified
    private(set) var collapsed: Set<String> = []
    private(set) var wraps = false
    private(set) var viewed: [String: ViewedMarks.Status] = [:]
    private var shown: DiffContent?
    /// Find matches by row; `isCurrent` marks the one the find bar points at.
    var findMatches: [Int: [(side: DiffSide, range: Range<Int>, isCurrent: Bool)]] = [:] {
        didSet { needsDisplay = true }
    }
    var isStale = false {
        didSet { if isStale != oldValue { needsDisplay = true } }
    }
    var selection: DiffSelection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }
    var onToggleCollapse: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onExpand: ((String, Int, ExpandDirection) -> Void)?
    var onToggleViewed: ((String) -> Void)?
    var onOpenThread: ((String) -> Void)?
    private(set) var threads: [String: [ThreadMarker]] = [:]
    private var threadedRows: [Int: Set<ThreadAnchor.Side>] = [:]
    var menuForFile: ((String) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = layout.row(at: point.y), case .fileHeader(let file) = layout.rows[row]
        else { return super.menu(for: event) }
        return menuForFile?(review.files[file].diff.path)
    }
    /// Nil follows the system's Increase Contrast setting; snapshot tests force it.
    var increaseContrastOverride: Bool?
    var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private(set) var font: NSFont
    private(set) var geometry = Geometry()
    private var lineCache: [LineKey: CTLine] = [:]
    var isDragging = false
    private var contents: [String: FileContents] = [:]
    /// Decoded previews by file index and side (true for new); decoded on first draw.
    private var images: [ImageKey: NSImage?] = [:]

    private struct ImageKey: Hashable {
        var file: Int
        var isNew: Bool
    }
    private let signposter = OSSignposter(subsystem: "com.danielhedren.seam", category: "DiffView")

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

    func show(_ content: DiffContent) {
        let interval = signposter.beginInterval("layoutDiff")
        defer { signposter.endInterval("layoutDiff", interval) }
        review = content.review
        contents = content.contents
        images.removeAll()
        mode = content.mode
        collapsed = content.collapsed
        wraps = content.wraps
        viewed = content.viewed
        threads = content.threads
        defer { shown = content }
        selection = nil
        if let shown, let files = Self.collapseOnlyChange(from: shown, to: content) {
            relayout(splicing: files, in: content)
            return
        }
        relayout(DiffRowBuilder.rows(for: content), width: geometry.visibleWidth)
    }

    /// The files whose collapse changed, when that (and viewed marks) is all that changed.
    static func collapseOnlyChange(from old: DiffContent, to new: DiffContent) -> [Int]? {
        var same = old
        same.collapsed = new.collapsed
        same.viewed = new.viewed
        guard same == new else { return nil }
        let changed = old.collapsed.symmetricDifference(new.collapsed)
        return new.review.files.indices.filter { changed.contains(new.review.files[$0].diff.path) }
    }

    /// Rebuilds only `files`, last first so earlier files' row positions stay valid: marking a
    /// file viewed collapses it, and rebuilding every row would cost a 20k-line diff tens of
    /// milliseconds per keypress.
    private func relayout(splicing files: [Int], in content: DiffContent) {
        var rows = layout.rows
        for file in files.reversed() {
            guard let start = layout.headerRow(ofFile: file) else { continue }
            let end = layout.headerRow(ofFile: file + 1) ?? layout.rows.count
            rows.replaceSubrange(start..<end, with: DiffRowBuilder.rows(forFile: file, in: content))
        }
        relayout(rows, width: geometry.visibleWidth)
    }

    /// A new font changes every row's metrics, so the layout is rebuilt at the new sizes.
    func setFont(_ font: NSFont) {
        guard font != self.font else { return }
        self.font = font
        let rows = layout.rows
        layout = DiffLayout(rows: [], metrics: Self.metrics(for: font))
        lineCache.removeAll(keepingCapacity: true)
        relayout(rows, width: geometry.visibleWidth)
    }

    /// Returns whether row heights changed, which only happens when wrapping.
    @discardableResult
    func setVisibleWidth(_ width: Double) -> Bool {
        guard width != geometry.visibleWidth else { return false }
        let wrapColumns = geometry.wrapColumns
        relayout(layout.rows, width: width)
        return geometry.wrapColumns != wrapColumns
    }

    private func relayout(_ rows: [DiffRow], width: Double) {
        geometry = Geometry(
            rows: rows, metrics: layout.metrics, mode: mode, visibleWidth: width, wraps: wraps)
        if rows != layout.rows || geometry.wrapColumns != layout.wrapColumns {
            layout = DiffLayout(
                rows: rows, metrics: layout.metrics, wrapColumns: geometry.wrapColumns)
            lineCache.removeAll(keepingCapacity: true)
        }
        threadedRows = DiffRowBuilder.threadedRows(rows, paths: paths, threads: threads)
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
        let palette = DiffPalette.current(
            for: effectiveAppearance, increaseContrast: increaseContrast)
        context.setFillColor(palette.background.nsColor.cgColor)
        context.fill(dirtyRect)
        if isStale { context.setAlpha(0.5) }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for index in layout.rows(in: dirtyRect.minY, dirtyRect.maxY) {
            let rect = NSRect(
                x: 0, y: layout.top(of: index), width: bounds.width,
                height: layout.height(of: index))
            draw(row: index, in: rect, palette: palette, context: context)
            if let sides = threadedRows[index] { drawThreadMark(sides, in: rect, context) }
        }
    }

    private func draw(row index: Int, in rect: NSRect, palette: DiffPalette, context: CGContext) {
        switch layout.rows[index] {
        case .fileHeader(let file):
            let path = review.files[file].diff.path
            DiffHeaderDrawing.draw(
                review.files[file], collapsed: collapsed.contains(path),
                viewed: viewed[path] ?? .unviewed, in: rect, font: font, palette: palette,
                context: context)
        case .hunkHeader(_, _, .hidden): break
        case .hunkHeader(_, _, .separator): fill(rect, palette.hunkBackground, context)
        case .hunkHeader(_, _, .titled(let text)):
            fill(rect, palette.hunkBackground, context)
            drawText(
                text, key: LineKey(row: index, side: .unified), x: geometry.unifiedTextX,
                rowTop: rect.minY, color: palette.hunkText, context: context)
        case .notice(_, let text):
            drawText(
                text, key: LineKey(row: index, side: .unified), x: geometry.unifiedTextX,
                rowTop: rect.minY, color: palette.gutterText, context: context)
        case .image(let file):
            drawImages(file: file, in: rect, palette: palette, context: context)
        case .thread(_, let marker):
            // A tint of its own, so a thread never reads as a hunk header or a gap.
            context.setFillColor(NSColor.systemYellow.withAlphaComponent(0.14).cgColor)
            context.fill(rect)
            let x =
                switch (mode, marker.side) {
                case (.unified, _): geometry.unifiedTextX
                case (.split, .old): geometry.splitTextOffset
                case (.split, .new): geometry.columnWidth + geometry.splitTextOffset
                }
            drawText(
                marker.text, key: LineKey(row: index, side: .unified), x: x,
                rowTop: rect.minY,
                color: marker.isResolved ? palette.gutterText : palette.text, context: context)
        case .gap(_, let gap):
            fill(rect, palette.hunkBackground, context)
            drawText(
                DiffRowBuilder.gapLabel(gap).text, key: LineKey(row: index, side: .unified),
                x: geometry.unifiedTextX, rowTop: rect.minY, color: palette.hunkText,
                context: context)
        case .line(_, let line):
            let column = Column(
                x: 0, width: rect.width, numbers: [line.old, line.new],
                textX: geometry.unifiedTextX)
            drawSide(
                kind: line.kind, text: line.text, noNewline: line.noNewline,
                highlights: line.highlights, syntax: line.syntax, column: column, row: index,
                side: .unified,
                rowTop: rect.minY, rowHeight: rect.height, palette: palette, context: context)
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
                    highlights: line.highlights, syntax: line.syntax, column: column, row: index,
                    side: side,
                    rowTop: rect.minY, rowHeight: rect.height, palette: palette, context: context)
                context.restoreGState()
            }
            context.setFillColor(palette.separator.nsColor.cgColor)
            context.fill(
                NSRect(x: geometry.columnWidth, y: rect.minY, width: 1, height: rect.height))
        }
    }

    /// A bar at the left of the gutter beside a thread's lines, on the side the thread is on.
    private func drawThreadMark(
        _ sides: Set<ThreadAnchor.Side>, in rect: NSRect, _ context: CGContext
    ) {
        context.setFillColor(NSColor.systemYellow.cgColor)
        for side in sides {
            let x = mode == .split && side == .new ? geometry.columnWidth : 0
            context.fill(NSRect(x: x, y: rect.minY, width: 3, height: rect.height))
        }
    }

    private struct Column {
        var x: Double
        var width: Double
        var numbers: [Int?]
        var textX: Double
    }

    private func drawSide(
        kind: DiffLine.Kind, text: String, noNewline: Bool, highlights: [Range<Int>],
        syntax: [SyntaxSpan],
        column: Column, row: Int,
        side: DiffSide, rowTop: Double, rowHeight: Double, palette: DiffPalette, context: CGContext
    ) {
        let height = rowHeight
        let lineHeight = layout.metrics.lineHeight
        let wrap = layout.wrapColumns
        let width = layout.metrics.characterWidth
        func rects(_ range: Range<Int>) -> [NSRect] {
            DiffLayout.segments(range, wrapColumns: wrap).map { segment in
                NSRect(
                    x: column.textX + Double(segment.columns.lowerBound) * width,
                    y: rowTop + Double(segment.line) * lineHeight,
                    width: Double(segment.columns.count) * width, height: lineHeight)
            }
        }
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
        if let word = kind == .added
            ? palette.addedWord : kind == .removed ? palette.removedWord : nil
        {
            for rect in highlights.flatMap(rects) { fill(rect, word, context) }
        }
        if let selection, selection.side == side,
            let range = selection.columns(inRow: row, length: text.count + 1), !range.isEmpty
        {
            let color =
                window?.firstResponder === self
                ? NSColor.selectedTextBackgroundColor
                : NSColor.unemphasizedSelectedTextBackgroundColor
            context.setFillColor(color.cgColor)
            for rect in rects(range) { context.fill(rect) }
        }
        for match in findMatches[row] ?? [] where match.side == side {
            let color = match.isCurrent ? palette.findCurrent : palette.findMatch
            for rect in rects(match.range) { fill(rect, color, context) }
        }
        let pieces = DiffLayout.segments(0..<text.count, wrapColumns: wrap)
        let characters = pieces.count > 1 ? Array(text) : []
        for piece in pieces {
            let offset = piece.line * (wrap ?? 0)
            let start = offset + piece.columns.lowerBound
            let end = offset + piece.columns.upperBound
            let chunk = pieces.count > 1 ? String(characters[start..<end]) : text
            let spans =
                pieces.count > 1
                ? syntax.compactMap { span -> SyntaxSpan? in
                    let lower = max(span.range.lowerBound, start)
                    let upper = min(span.range.upperBound, end)
                    guard lower < upper else { return nil }
                    return SyntaxSpan(range: (lower - start)..<(upper - start), token: span.token)
                } : syntax
            drawText(
                chunk, key: LineKey(row: row, side: side, chunk: piece.line), x: column.textX,
                rowTop: rowTop + Double(piece.line) * lineHeight, color: palette.text,
                syntax: spans, palette: palette, context: context)
        }
        if noNewline, let last = pieces.last {
            let x = column.textX + Double(last.columns.upperBound + 1) * width
            drawText(
                String(localized: "⊘ no newline at end of file", bundle: .module), key: nil, x: x,
                rowTop: rowTop + Double(last.line) * lineHeight, color: palette.gutterText,
                context: context)
        }
    }

    /// Old on the left, new on the right, each fitted into its half with its aspect ratio kept.
    private func drawImages(
        file: Int, in rect: NSRect, palette: DiffPalette, context: CGContext
    ) {
        let path = review.files[file].diff.path
        fill(
            NSRect(x: rect.midX, y: rect.minY + 8, width: 1, height: rect.height - 16),
            palette.separator, context)
        for isNew in [false, true] {
            let half = NSRect(
                x: rect.minX + (isNew ? rect.width / 2 : 0), y: rect.minY, width: rect.width / 2,
                height: rect.height
            ).insetBy(dx: 16, dy: 12)
            let key = ImageKey(file: file, isNew: isNew)
            if images[key] == nil {
                let data = isNew ? contents[path]?.newImage : contents[path]?.oldImage
                images[key] = .some(data.flatMap(NSImage.init(data:)))
            }
            guard let image = images[key] ?? nil, image.size.width > 0, image.size.height > 0
            else {
                fill(half, palette.emptySide, context)
                continue
            }
            let scale = min(half.width / image.size.width, half.height / image.size.height, 1)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let target = NSRect(
                x: half.midX - size.width / 2, y: half.midY - size.height / 2, width: size.width,
                height: size.height)
            image.draw(
                in: target, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }

    private func fill(_ rect: NSRect, _ color: RGB, _ context: CGContext) {
        context.setFillColor(color.nsColor.cgColor)
        context.fill(rect)
    }

    private func drawText(
        _ text: String, key: LineKey?, x: Double, rowTop: Double, color: RGB,
        syntax: [SyntaxSpan] = [], palette: DiffPalette? = nil, context: CGContext
    ) {
        guard !text.isEmpty else { return }
        let line: CTLine
        if let key, let cached = lineCache[key] {
            line = cached
        } else {
            line =
                if let palette, !syntax.isEmpty {
                    TextLine.make(
                        text, font: font, syntax: syntax, palette: palette, plain: color)
                } else {
                    TextLine.make(text, font: font)
                }
            if let key {
                if lineCache.count > 20_000 { lineCache.removeAll(keepingCapacity: true) }
                lineCache[key] = line
            }
        }
        context.setFillColor(color.nsColor.cgColor)
        context.textPosition = CGPoint(x: x, y: rowTop + 2 + font.ascender)
        CTLineDraw(line, context)
    }

    /// Cached lines carry syntax colours for the old appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    func appearanceOptionsChanged() {
        lineCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }
}

private struct LineKey: Hashable {
    var row: Int
    var side: DiffSide
    /// The visual line within a wrapped row.
    var chunk = 0
}
