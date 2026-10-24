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
    private(set) var sinceViewed: Set<String> = []
    private var shown: DiffContent?
    /// Find matches by row; `isCurrent` marks the one the find bar points at.
    var findMatches: [Int: [(side: DiffSide, range: Range<Int>, isCurrent: Bool)]] = [:] {
        didSet { needsDisplay = true }
    }
    var isStale = false {
        didSet { if isStale != oldValue { needsDisplay = true } }
    }
    var selection: DiffSelection? {
        didSet {
            guard selection != oldValue else { return }
            updateTargetRows()
            needsDisplay = true
        }
    }
    /// The lines `c` would comment on, or the open draft's, by row: marked so the reader sees
    /// what a new thread goes on before writing it.
    private(set) var targetRows: [Int: ThreadAnchor.Side] = [:]
    /// The row under the sticky header: what `c`, `t` and `o` act on with nothing selected,
    /// marked while the diff has focus so that target isn't invisible.
    var readingRow: Int? {
        didSet {
            guard readingRow != oldValue, selection == nil, hasFocus else { return }
            updateTargetRows()
            needsDisplay = true
        }
    }
    private(set) var hasFocus = false
    var onToggleCollapse: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onExpand: ((String, Int, ExpandDirection) -> Void)?
    var onToggleViewed: ((String) -> Void)?
    var viewedHelp: ((ViewedMarks.Status) -> String)?
    var onOpenThread: ((String) -> Void)?
    var onCloseCard: (() -> Void)?
    private(set) var threads: [String: [ThreadMarker]] = [:]
    private var resolvedMarks: [String: [ThreadMarker]] = [:]
    private var threadedRows: [Int: Set<ThreadMark>] = [:]
    var menuForFile: ((String) -> NSMenu?)?
    var menuForLines: (() -> NSMenu?)?
    /// The card's view, which Features supplies; the canvas sizes and places it.
    var makeCardView: ((DiffCard) -> any DiffCardView)?
    var shownCard: (card: DiffCard, view: any DiffCardView)?
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
        hasFocus = true
        updateTargetRows()
        needsDisplay = true
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        updateTargetRows()
        needsDisplay = true
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
        sinceViewed = content.sinceViewed
        threads = content.threads
        resolvedMarks = content.resolvedMarks
        defer { shown = content }
        selection = nil
        if let shown, let files = Self.spliceableChange(from: shown, to: content) {
            relayout(splicing: files, in: content)
            return
        }
        relayout(DiffRowBuilder.rows(for: content), width: geometry.visibleWidth)
    }

    /// The files to rebuild when collapses, viewed marks and the draft are all that changed.
    static func spliceableChange(from old: DiffContent, to new: DiffContent) -> [Int]? {
        var same = old
        same.collapsed = new.collapsed
        same.viewed = new.viewed
        same.draft = new.draft
        same.openThread = new.openThread
        guard same == new else { return nil }
        var changed = old.collapsed.symmetricDifference(new.collapsed)
        if old.draft != new.draft {
            for draft in [old.draft, new.draft] { if let draft { changed.insert(draft.path) } }
        }
        if old.openThread != new.openThread {
            for (path, markers) in new.threads
            where markers.contains(where: { [old.openThread, new.openThread].contains($0.id) }) {
                changed.insert(path)
            }
        }
        return new.review.files.indices.filter { changed.contains(new.review.files[$0].diff.path) }
    }

    var shownDraft: DraftMarker? { shown?.draft }
    var shownOpenThread: String? { shown?.openThread }

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
        let cardHeight = cardHeight(in: rows)
        if rows != layout.rows || geometry.wrapColumns != layout.wrapColumns
            || cardHeight != layout.cardHeight
        {
            layout = DiffLayout(
                rows: rows, metrics: layout.metrics, wrapColumns: geometry.wrapColumns,
                cardHeight: cardHeight)
            lineCache.removeAll(keepingCapacity: true)
        }
        threadedRows = DiffRowBuilder.threadedRows(
            rows, paths: paths, threads: threads, resolved: resolvedMarks)
        resize()
        updateCardView()
        updateTargetRows()
    }

    /// The card's view needs another height: the same rows, measured again.
    func remeasureCard() {
        relayout(layout.rows, width: geometry.visibleWidth)
    }

    private func resize() {
        let size = NSSize(width: geometry.documentWidth, height: max(layout.totalHeight, 1))
        if frame.size != size { setFrameSize(size) }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
            if let marks = threadedRows[index] {
                drawThreadMark(marks, in: rect, palette: palette, context)
            }
            if let side = targetRows[index] { drawTargetMark(side, in: rect, context) }
        }
    }

    private func draw(row index: Int, in rect: NSRect, palette: DiffPalette, context: CGContext) {
        switch layout.rows[index] {
        case .fileHeader(let file):
            let path = review.files[file].diff.path
            DiffHeaderDrawing.draw(
                review.files[file], collapsed: collapsed.contains(path),
                viewed: viewed[path] ?? .unviewed, sinceViewed: sinceViewed.contains(path),
                in: chromeRect(ofRow: index), font: font,
                palette: palette, context: context,
                topBorder: index == 0 || !layout.rows[index - 1].isFileHeader)
        case .hunkHeader(_, _, .hidden): break
        case .hunkHeader(_, _, .separator): fill(rect, palette.hunkBackground, context)
        case .hunkHeader(_, _, .titled(let text)):
            fill(rect, palette.hunkBackground, context)
            drawText(
                text, key: LineKey(row: index, side: .unified), x: geometry.chromeTextX,
                rowTop: rect.minY, color: palette.hunkText, context: context)
        case .notice(_, let text):
            drawText(
                text, key: LineKey(row: index, side: .unified), x: geometry.chromeTextX,
                rowTop: rect.minY, color: palette.gutterText, context: context)
        case .image(let file):
            drawImages(file: file, in: chromeRect(ofRow: index), palette: palette, context: context)
        case .draft(_, let marker):
            drawCardFrame(row: index, side: marker.side, palette: palette, context: context)
        case .openThread(_, let marker):
            drawCardFrame(
                row: index, side: marker.side, source: marker.source, isNote: marker.isNote,
                palette: palette,
                context: context)
        case .thread(_, let marker):
            drawThreadRow(marker, row: index, in: rect, palette: palette, context: context)
        case .gap(_, let gap):
            fill(rect, palette.hunkBackground, context)
            drawText(
                DiffRowBuilder.gapLabel(gap).text, key: LineKey(row: index, side: .unified),
                x: geometry.chromeTextX, rowTop: rect.minY, color: palette.hunkText,
                context: context)
        case .line(_, let line):
            draw(
                LineCell(line), side: .unified, row: index, in: rect, palette: palette,
                context: context)
        case .split(_, let left, let right):
            for (line, side) in [(left, DiffSide.left), (right, DiffSide.right)] {
                let bounds = NSRect(
                    x: side == .left ? 0 : geometry.columnWidth, y: rect.minY,
                    width: geometry.columnWidth, height: rect.height)
                guard let line else {
                    fill(bounds, palette.emptySide, context)
                    continue
                }
                // Long lines are clipped at the column edge rather than spilling into the other.
                context.saveGState()
                context.clip(to: bounds)
                draw(
                    LineCell(line), side: side, row: index, in: bounds, palette: palette,
                    context: context)
                context.restoreGState()
            }
            context.setFillColor(palette.separator.nsColor.cgColor)
            context.fill(
                NSRect(x: geometry.columnWidth, y: rect.minY, width: 1, height: rect.height))
        }
    }

    /// File headers and image previews span the visible width, not a document a long line made
    /// wider, so the viewed checkbox sits where the sticky header puts it.
    func chromeRect(ofRow row: Int) -> NSRect {
        let visible = visibleRect.isEmpty ? bounds : visibleRect
        return NSRect(
            x: visible.minX, y: layout.top(of: row), width: visible.width,
            height: layout.height(of: row))
    }

    /// Chrome rows follow the visible width, so a horizontal scroll has to redraw them.
    func horizontalScrollDidChange() {
        for row in layout.rows(in: visibleRect.minY, visibleRect.maxY) {
            switch layout.rows[row] {
            case .fileHeader, .image, .draft, .openThread:
                setNeedsDisplay(
                    NSRect(
                        x: 0, y: layout.top(of: row), width: bounds.width,
                        height: layout.height(of: row)))
            default: break
            }
        }
        updateCardView()
    }

    /// A tint of its own, so a thread never reads as a hunk header or a gap. Side by side it
    /// keeps to its column, the other left empty as beside an unpaired line.
    private func drawThreadRow(
        _ marker: ThreadMarker, row: Int, in rect: NSRect, palette: DiffPalette,
        context: CGContext
    ) {
        var band = rect
        var side = DiffSide.unified
        if mode == .split {
            side = marker.side == .old ? .left : .right
            let (own, other) = rect.divided(
                atDistance: geometry.columnWidth, from: side == .left ? .minXEdge : .maxXEdge)
            band = own
            fill(other, palette.emptySide, context)
        }
        context.setFillColor(ThreadColor.wash(marker.source, note: marker.isNote).cgColor)
        context.fill(band)
        let x = geometry.textX(for: side)
        let color = marker.isResolved ? palette.gutterText : palette.text
        let columns = Int((band.maxX - geometry.padding - x) / layout.metrics.characterWidth)
        if mode == .unified || marker.text.count <= columns {
            drawText(marker.text, key: nil, x: x, rowTop: rect.minY, color: color, context: context)
        } else {
            let tally = "   " + marker.tally
            let room = Double(max(columns - tally.count, 1)) * layout.metrics.characterWidth
            let summary = TextLine.make(marker.summary, font: font)
            let line =
                CTLineCreateTruncatedLine(summary, room, .end, TextLine.make("…", font: font))
                ?? summary
            context.setFillColor(color.nsColor.cgColor)
            context.textPosition = CGPoint(x: x, y: rect.minY + 2 + font.ascender)
            CTLineDraw(line, context)
            let tallyX = x + CTLineGetTypographicBounds(line, nil, nil, nil)
            drawText(tally, key: nil, x: tallyX, rowTop: rect.minY, color: color, context: context)
        }
        if mode == .split {
            fill(
                NSRect(x: geometry.columnWidth, y: rect.minY, width: 1, height: rect.height),
                palette.separator, context)
        }
    }

    /// A bar at the left of the gutter beside a thread's lines, on the side the thread is on;
    /// where both Seam's and GitHub's threads cover a line, GitHub's bar is beside Seam's.
    private func drawThreadMark(
        _ marks: Set<ThreadMark>, in rect: NSRect, palette: DiffPalette, _ context: CGContext
    ) {
        for mark in marks {
            var x = mode == .split && mark.side == .new ? geometry.columnWidth : 0
            if mark.source == .gitHub, marks.contains(ThreadMark(side: mark.side, source: .seam)) {
                x += 3
            }
            let bar = NSRect(x: x, y: rect.minY, width: 3, height: rect.height)
            let color = ThreadColor.accent(mark.source, note: mark.isNote).cgColor
            // Hollow and grey, as resolved threads are elsewhere: only the sides, so a run of lines
            // reads as one outlined bar.
            if mark.isResolved {
                context.setFillColor(palette.gutterText.nsColor.cgColor)
                context.fill(NSRect(x: bar.minX, y: bar.minY, width: 1, height: bar.height))
                context.fill(NSRect(x: bar.maxX - 1, y: bar.minY, width: 1, height: bar.height))
            } else {
                context.setFillColor(color)
                context.fill(bar)
            }
        }
    }

    /// The bar beside a line a new thread goes on; its gutter's wash is drawn with the line.
    private func drawTargetMark(_ side: ThreadAnchor.Side, in rect: NSRect, _ context: CGContext) {
        let x = mode == .split && side == .new ? geometry.columnWidth : 0
        context.setFillColor(ThreadColor.accent.cgColor)
        context.fill(NSRect(x: x, y: rect.minY, width: 3, height: rect.height))
    }

    private func isCommentTarget(row: Int, side: DiffSide) -> Bool {
        switch (targetRows[row], side) {
        case (nil, _): false
        case (_, .unified), (.old?, .left), (.new?, .right): true
        default: false
        }
    }

    /// One side's line in `bounds`: the whole row in unified mode, its column in split mode.
    private func draw(
        _ cell: LineCell, side: DiffSide, row: Int, in bounds: NSRect, palette: DiffPalette,
        context: CGContext
    ) {
        let (text, syntax) = (cell.text, cell.syntax)
        let rowTop = bounds.minY
        let textX = geometry.textX(for: side)
        let lineHeight = layout.metrics.lineHeight
        let wrap = layout.wrapColumns
        let width = layout.metrics.characterWidth
        func rects(_ range: Range<Int>) -> [NSRect] {
            DiffLayout.segments(range, wrapColumns: wrap).map { segment in
                NSRect(
                    x: textX + Double(segment.columns.lowerBound) * width,
                    y: rowTop + Double(segment.line) * lineHeight,
                    width: Double(segment.columns.count) * width, height: lineHeight)
            }
        }
        let gutterWidth = geometry.numberWidth * Double(cell.numbers.count)
        let (background, gutter, word, marker, symbol): (RGB?, RGB?, RGB?, RGB, String) =
            switch cell.kind {
            case .added:
                (
                    palette.addedBackground, palette.addedGutter, palette.addedWord,
                    palette.addedMarker, "+"
                )
            case .removed:
                (
                    palette.removedBackground, palette.removedGutter, palette.removedWord,
                    palette.removedMarker, "−"
                )
            case .context: (nil, nil, nil, palette.gutterText, " ")
            }
        if let background { fill(bounds, background, context) }
        let gutterRect = NSRect(
            x: bounds.minX, y: rowTop, width: gutterWidth, height: bounds.height)
        if let gutter { fill(gutterRect, gutter, context) }
        // The wash goes under the numbers, which take the text colour to stay legible on it.
        let isTarget = isCommentTarget(row: row, side: side)
        if isTarget {
            context.setFillColor(
                ThreadColor.accent.withAlphaComponent(palette.targetAlpha).cgColor)
            context.fill(gutterRect)
        }
        for (offset, number) in cell.numbers.enumerated() {
            guard let number else { continue }
            let label = String(number)
            let right = bounds.minX + geometry.numberWidth * Double(offset + 1) - geometry.padding
            drawText(
                label, key: nil, x: right - Double(label.count) * layout.metrics.characterWidth,
                rowTop: rowTop, color: isTarget ? palette.text : palette.gutterText,
                context: context)
        }
        drawText(
            symbol, key: nil, x: bounds.minX + gutterWidth + geometry.padding / 2, rowTop: rowTop,
            color: marker, context: context)
        if let word {
            for rect in cell.highlights.flatMap(rects) { fill(rect, word, context) }
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
                chunk, key: LineKey(row: row, side: side, chunk: piece.line), x: textX,
                rowTop: rowTop + Double(piece.line) * lineHeight, color: palette.text,
                syntax: spans, palette: palette, context: context)
        }
        if cell.noNewline, let last = pieces.last {
            let x = textX + Double(last.columns.upperBound + 1) * width
            drawText(
                String(localized: "⊘ no newline at end of file", bundle: .module), key: nil, x: x,
                rowTop: rowTop + Double(last.line) * lineHeight, color: palette.gutterText,
                context: context)
        }
    }

    /// Old on the left, new on the right, each fitted into its half with its aspect ratio kept
    /// and captioned with its side and pixel size. A missing side stays an empty fill.
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
            guard half.width > 0, half.height > 0 else { continue }
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
            let captionTop = half.maxY - layout.metrics.lineHeight
            let area = NSRect(
                x: half.minX, y: half.minY, width: half.width,
                height: max(0, captionTop - 6 - half.minY))
            let scale = min(area.width / image.size.width, area.height / image.size.height, 1)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let target = NSRect(
                x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width,
                height: size.height)
            drawCheckerboard(in: target, palette: palette, context: context)
            image.draw(
                in: target, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            let pixels = Self.pixelSize(of: image)
            let side =
                isNew
                ? String(localized: "New", bundle: .module)
                : String(localized: "Old", bundle: .module)
            let caption = String(
                localized: "\(side) · \(pixels.width) × \(pixels.height)", bundle: .module)
            drawCaption(
                [caption, side], centeredIn: half.minX..<half.maxX, rowTop: captionTop,
                color: palette.gutterText, context: context)
        }
    }

    /// The bitmap's pixels, so a Retina screenshot reads at its real size; vector images have
    /// no pixels and give their size in points.
    static func pixelSize(of image: NSImage) -> (width: Int, height: Int) {
        let bitmap = image.representations.filter { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }
            .max { $0.pixelsWide < $1.pixelsWide }
        if let bitmap { return (bitmap.pixelsWide, bitmap.pixelsHigh) }
        return (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
    }

    private func drawCheckerboard(in rect: NSRect, palette: DiffPalette, context: CGContext) {
        let square = 8.0
        fill(rect, palette.background, context)
        context.saveGState()
        context.clip(to: rect)
        context.setFillColor(palette.checker.nsColor.cgColor)
        for row in 0..<Int((rect.height / square).rounded(.up)) {
            for column in stride(from: row % 2, to: Int((rect.width / square).rounded(.up)), by: 2)
            {
                context.fill(
                    CGRect(
                        x: rect.minX + Double(column) * square,
                        y: rect.minY + Double(row) * square, width: square, height: square))
            }
        }
        context.restoreGState()
    }

    /// The first choice that fits the half, else the last shortened, so the two never meet.
    private func drawCaption(
        _ choices: [String], centeredIn span: Range<Double>, rowTop: Double, color: RGB,
        context: CGContext
    ) {
        let room = span.upperBound - span.lowerBound
        let lines = choices.map { TextLine.make($0, font: font) }
        guard
            let line = lines.first(where: { CTLineGetTypographicBounds($0, nil, nil, nil) <= room })
                ?? lines.last.flatMap({
                    CTLineCreateTruncatedLine($0, room, .end, TextLine.make("…", font: font))
                })
        else { return }
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.setFillColor(color.nsColor.cgColor)
        context.textPosition = CGPoint(
            x: (span.lowerBound + (room - width) / 2).rounded(), y: rowTop + 2 + font.ascender)
        CTLineDraw(line, context)
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

/// What drawing needs from a unified line or one side of a split row.
private struct LineCell {
    var kind: DiffLine.Kind
    var text: String
    var noNewline: Bool
    var highlights: [Range<Int>]
    var syntax: [SyntaxSpan]
    /// Gutter numbers, left to right; nil leaves a slot blank.
    var numbers: [Int?]

    init(_ line: UnifiedLine) {
        (kind, text, noNewline) = (line.kind, line.text, line.noNewline)
        (highlights, syntax, numbers) = (line.highlights, line.syntax, [line.old, line.new])
    }

    init(_ line: SideLine) {
        (kind, text, noNewline) = (line.kind, line.text, line.noNewlineAtEnd)
        (highlights, syntax, numbers) = (line.highlights, line.syntax, [line.number])
    }
}

private struct LineKey: Hashable {
    var row: Int
    var side: DiffSide
    /// The visual line within a wrapped row.
    var chunk = 0
}

// MARK: - Card frame

extension DiffCanvasView {
    /// The card's frame: its side's column in split mode, the visible width in unified.
    func draftFrame(row: Int, side: ThreadAnchor.Side) -> NSRect {
        var rect = chromeRect(ofRow: row)
        if mode == .split {
            rect.origin.x = side == .old ? 0 : geometry.columnWidth
            rect.size.width = geometry.columnWidth
        }
        return rect.insetBy(dx: 8, dy: 4)
    }

    /// The card a draft and an open thread sit in, amber or GitHub's blue; side by side, the
    /// other column is left empty as beside an unpaired line.
    func drawCardFrame(
        row: Int, side: ThreadAnchor.Side, source: ThreadSource = .seam, isNote: Bool = false,
        palette: DiffPalette,
        context: CGContext
    ) {
        if mode == .split {
            let rect = chromeRect(ofRow: row)
            fill(
                NSRect(
                    x: side == .old ? geometry.columnWidth : 0, y: rect.minY,
                    width: geometry.columnWidth, height: rect.height),
                palette.emptySide, context)
            fill(
                NSRect(x: geometry.columnWidth, y: rect.minY, width: 1, height: rect.height),
                palette.separator, context)
        }
        let frame = draftFrame(row: row, side: side)
        let shape = CGPath(
            roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(shape)
        context.setFillColor(palette.background.nsColor.cgColor)
        context.fillPath()
        context.addPath(shape)
        context.setFillColor(ThreadColor.wash(source, note: isNote).cgColor)
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(ThreadColor.accent(source, note: isNote).cgColor)
        context.setLineWidth(1)
        context.strokePath()
    }

    var draftRow: Int? {
        layout.rows.firstIndex { if case .draft = $0 { true } else { false } }
    }
}

// MARK: - Comment target

extension DiffCanvasView {
    fileprivate func updateTargetRows() {
        let target: (file: Int, side: ThreadAnchor.Side, lines: ClosedRange<Int>)?
        if let row = draftRow, case .draft(let file, let draft) = layout.rows[row] {
            target = (file, draft.side, draft.lines)
        } else if let selection {
            target = commentTarget(fallback: selection.head.row)
        } else if hasFocus, let readingRow {
            target = commentTarget(fallback: readingRow)
        } else {
            target = nil
        }
        guard let target, let header = layout.headerRow(ofFile: target.file) else {
            targetRows = [:]
            return
        }
        let end = layout.headerRow(ofFile: target.file + 1) ?? layout.rows.count
        var rows: [Int: ThreadAnchor.Side] = [:]
        for index in header..<end {
            if let number = DiffRowBuilder.number(of: layout.rows[index], on: target.side),
                target.lines.contains(number)
            {
                rows[index] = target.side
            }
        }
        targetRows = rows
    }
}
